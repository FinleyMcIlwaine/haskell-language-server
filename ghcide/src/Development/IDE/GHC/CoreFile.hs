{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}

-- | CoreFiles let us serialize Core to a file in order to later recover it
-- without reparsing or retypechecking
module Development.IDE.GHC.CoreFile  where

import Data.IORef
import Data.Foldable
import Data.List (isPrefixOf)
import Control.Monad.IO.Class
import Control.Monad

import Development.IDE.GHC.Compat

#if MIN_VERSION_ghc(9,0,0)
import GHC.Utils.Binary
import GHC.Core
import GHC.CoreToIface
import GHC.IfaceToCore
import GHC.Iface.Env
import GHC.Iface.Binary

#if MIN_VERSION_ghc(9,2,0)
import GHC.Types.TypeEnv
#else
import GHC.Driver.Types
#endif

#elif MIN_VERSION_ghc(8,6,0)
import Binary
import CoreSyn
import ToIface
import TcIface
import IfaceEnv
import BinIface
import HscTypes
#endif

-- | Initial ram buffer to allocate for writing interface files
initBinMemSize :: Int
initBinMemSize = 1024 * 1024


newtype CoreFile = CoreFile { cf_bindings :: [TopIfaceBinding IfaceId] }

data TopIfaceBinding v
  = TopIfaceNonRec v IfaceExpr
  | TopIfaceRec    [(v, IfaceExpr)]
  deriving (Functor, Foldable, Traversable)

-- | GHC doesn't export 'tcIdDetails', 'tcIfaceInfo', or 'tcIfaceType',
-- but it does export 'tcIfaceDecl'
-- so we use `IfaceDecl` as a container for all of these, as wel
-- invariant: 'IfaceId' is always a 'IfaceId' constructor
type IfaceId = IfaceDecl

instance Binary (TopIfaceBinding IfaceId) where
  put_ bh (TopIfaceNonRec d e) = do
    putByte bh 0
    put_ bh d
    put_ bh e
  put_ bh (TopIfaceRec vs) = do
    putByte bh 1
    put_ bh vs
  get bh = do
    t <- getByte bh
    case t of
      0 -> TopIfaceNonRec <$> get bh <*> get bh
      1 -> TopIfaceRec <$> get bh
      _ -> error "Binary TopIfaceBinding"

instance Binary CoreFile where
  put_ bh (CoreFile a) = put_ bh a
  get bh = CoreFile <$> get bh

readBinCoreFile
  :: NameCacheUpdater
  -> FilePath
  -> IO CoreFile
readBinCoreFile name_cache fat_hi_path = do
    bh <- readBinMem fat_hi_path
    getWithUserData name_cache bh

-- | Write an interface file
writeBinCoreFile :: FilePath -> CoreFile -> IO ()
writeBinCoreFile core_path fat_iface = do
    bh <- openBinMem initBinMemSize

    let quietTrace =
#if MIN_VERSION_ghc(9,2,0)
          QuietBinIFace
#else
          (const $ pure ())
#endif

    putWithUserData quietTrace bh fat_iface

    -- And send the result to the file
    writeBinMem bh core_path

codeGutsToCoreFile :: CgGuts -> CoreFile
codeGutsToCoreFile CgGuts{..} = CoreFile (map (toIfaceTopBind cg_module) cg_binds)

toIfaceTopBndr :: Module -> Id -> IfaceId
toIfaceTopBndr mod id
  = IfaceId (mangleDeclName mod $ getName id)
            (toIfaceType (idType id))
            (toIfaceIdDetails (idDetails id))
            (toIfaceIdInfo (idInfo id))

toIfaceTopBind :: Module -> Bind Id -> TopIfaceBinding IfaceId
toIfaceTopBind mod (NonRec b r) = TopIfaceNonRec (toIfaceTopBndr mod b) (toIfaceExpr r)
toIfaceTopBind mod (Rec prs)    = TopIfaceRec [(toIfaceTopBndr mod b, toIfaceExpr r) | (b,r) <- prs]

typecheckCoreFile :: Module -> IORef TypeEnv -> CoreFile -> IfG CoreProgram
typecheckCoreFile this_mod type_var (CoreFile prepd_binding) =
  initIfaceLcl this_mod (text "typecheckCoreFile") NotBoot $ do
    tcTopIfaceBindings type_var prepd_binding

mangleDeclName :: Module -> Name -> Name
mangleDeclName mod name
  | isExternalName name = name
  | otherwise = mkExternalName (nameUnique name) (mangleModule mod) (nameOccName name) (nameSrcSpan name)

mangleModule :: Module -> Module
mangleModule mod = mkModule (moduleUnitId mod) (mkModuleName $ "GHCIDEINTERNAL" ++ moduleNameString (moduleName mod))

isGhcideModule :: Module -> Bool
isGhcideModule mod = "GHCIDEINTERNAL" `isPrefixOf` (moduleNameString $ moduleName mod)

isGhcideName :: Name -> Bool
isGhcideName = isGhcideModule . nameModule

tcTopIfaceBindings :: IORef TypeEnv -> [TopIfaceBinding IfaceId]
          -> IfL [CoreBind]
tcTopIfaceBindings ty_var ver_decls
   = do
     int <- mapM (traverse $ tcIfaceId) ver_decls
     let all_ids = concatMap toList int
     liftIO $ modifyIORef ty_var (flip extendTypeEnvList $ map AnId all_ids)
     extendIfaceIdEnv all_ids $ mapM tc_iface_bindings int

tcIfaceId :: IfaceId -> IfL Id
tcIfaceId = fmap getIfaceId . tcIfaceDecl False <=< unmangle_decl_name
  where
    unmangle_decl_name ifid@IfaceId{ ifName = name }
      | isGhcideName name = do
        name' <- newIfaceName (mkVarOcc $ getOccString name)
        pure $ ifid{ ifName = name' }
      | otherwise = pure ifid
    -- invariant: 'IfaceId' is always a 'IfaceId' constructor
    getIfaceId (AnId id) = id
    getIfaceId _ = error "tcIfaceId: got non Id"

tc_iface_bindings :: TopIfaceBinding Id -> IfL CoreBind
tc_iface_bindings (TopIfaceNonRec v e) = do
  e' <- tcIfaceExpr e
  pure $ NonRec v e'
tc_iface_bindings (TopIfaceRec vs) = do
  vs' <- traverse (\(v, e) -> (,) <$> pure v <*> tcIfaceExpr e) vs
  pure $ Rec vs'