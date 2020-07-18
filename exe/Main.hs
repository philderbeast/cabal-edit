{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main
  ( main,
  )
where

import Control.Monad
import qualified Data.ByteString as BS
import Data.List
import Data.Map as Map
import Data.Maybe
import Data.Set as Set
import Data.Store
import Data.Time.Clock
import qualified Distribution.Hackage.DB.Parsed as P
import Distribution.Hackage.DB.Path
import qualified Distribution.Hackage.DB.Unparsed as U
import Distribution.PackageDescription.Parsec
import Distribution.PackageDescription.PrettyPrint
import Distribution.Parsec
import Distribution.Pretty
import Distribution.Types.BuildInfo
import Distribution.Types.CondTree
import Distribution.Types.Dependency
import Distribution.Types.GenericPackageDescription
import Distribution.Types.Library
import Distribution.Types.LibraryName
import Distribution.Types.PackageDescription
import Distribution.Types.PackageName
import Distribution.Types.Version
import Distribution.Types.VersionRange.Internal
import Distribution.Utils.ShortText
import Distribution.Verbosity
import Options.Applicative
import System.Directory
import System.Exit
import System.FilePath.Glob
import System.FilePath.Posix

-------------------------------------------------------------------------------
-- Library Manipulation
-------------------------------------------------------------------------------

buildInfo :: GenericPackageDescription -> Maybe BuildInfo
buildInfo GenericPackageDescription {..} = fmap go condLibrary
  where
    go (CondNode Library {..} _ _) = libBuildInfo

setBuildInfo ::
  BuildInfo ->
  GenericPackageDescription ->
  GenericPackageDescription
setBuildInfo binfo pkg@GenericPackageDescription {..} = pkg {condLibrary = fmap go condLibrary}
  where
    go (CondNode var deps libs) = CondNode (var {libBuildInfo = binfo}) deps libs

addLibDep ::
  Dependency ->
  BuildInfo ->
  BuildInfo
addLibDep dep binfo@BuildInfo {..} = binfo {targetBuildDepends = targetBuildDepends <> [dep]}

setLibDeps ::
  [Dependency] ->
  BuildInfo ->
  BuildInfo
setLibDeps deps binfo@BuildInfo {} = binfo {targetBuildDepends = deps}

hasLib :: GenericPackageDescription -> IO ()
hasLib pkg =
  if hasLibs (packageDescription pkg)
    then pure ()
    else die "Package has no public library. Cannot modify dependencies."

-------------------------------------------------------------------------------
-- Dependency Manipulation
-------------------------------------------------------------------------------

getDeps ::
  GenericPackageDescription ->
  [Dependency]
getDeps pkg = concat (maybeToList depends)
  where
    depends = fmap targetBuildDepends (buildInfo pkg)

setDeps ::
  [Dependency] ->
  GenericPackageDescription ->
  GenericPackageDescription
setDeps deps pkg@GenericPackageDescription {..} = pkg {condLibrary = fmap go condLibrary}
  where
    go (CondNode var@Library {..} libdeps libs) =
      CondNode (var {libBuildInfo = setLibDeps deps libBuildInfo}) libdeps libs

modifyDeps ::
  (PackageName -> Dependency -> Dependency) ->
  GenericPackageDescription ->
  GenericPackageDescription
modifyDeps f pkg = setDeps [f (depPkgName dep) dep | dep <- getDeps pkg] pkg

-------------------------------------------------------------------------------
-- DepMap
-------------------------------------------------------------------------------

udpateDep ::
  GenericPackageDescription ->
  (PackageName -> Dependency -> Maybe Dependency) ->
  PackageName ->
  Map PackageName Dependency
udpateDep pkg f pk = Map.updateWithKey f pk (depMap pkg)

lookupDep :: GenericPackageDescription -> PackageName -> Maybe Dependency
lookupDep pkg pk = Map.lookup pk (depMap pkg)

modifyDep :: GenericPackageDescription -> PackageName -> Dependency -> GenericPackageDescription
modifyDep pkg pk dep = setDepMap (Map.insert pk dep (depMap pkg)) pkg

deleteDep :: GenericPackageDescription -> PackageName -> GenericPackageDescription
deleteDep pkg pk = setDepMap (Map.delete pk (depMap pkg)) pkg

setDepMap :: Map.Map PackageName Dependency -> GenericPackageDescription -> GenericPackageDescription
setDepMap pkm = setDeps (fmap snd (Map.toList pkm))

depMap :: GenericPackageDescription -> Map.Map PackageName Dependency
depMap pkg = Map.fromList [(depPkgName dep, dep) | dep <- getDeps pkg]

-------------------------------------------------------------------------------
-- Dependency Addition
-------------------------------------------------------------------------------

add ::
  Dependency ->
  (FilePath, GenericPackageDescription) ->
  IO GenericPackageDescription
add dep (fname, cabalFile) =
  case depVerRange dep of
    AnyVersion -> do
      let pk = depPkgName dep
      verMap <- cacheDeps
      -- Lookup the latest version and use the majorBound of it.
      ver <- case Map.lookup pk verMap of
        Nothing -> die $ "No such package named: " ++ show pk
        Just vers -> pure (maximum vers)
      let dependency = Dependency pk (majorBoundVersion (majorUpperBound ver)) (Set.singleton defaultLibName)
      putStrLn $ "Adding latest dependency: " ++ prettyShow dependency ++ " to " ++ takeFileName fname
      pure $ modifyDep cabalFile pk dependency
    ThisVersion givenVersion -> addVer ThisVersion givenVersion (fname, cabalFile) dep
    LaterVersion givenVersion -> addVer LaterVersion givenVersion (fname, cabalFile) dep
    OrLaterVersion givenVersion -> addVer OrLaterVersion givenVersion (fname, cabalFile) dep
    EarlierVersion givenVersion -> addVer EarlierVersion givenVersion (fname, cabalFile) dep
    WildcardVersion givenVersion -> addVer WildcardVersion givenVersion (fname, cabalFile) dep
    givenVersion -> die $ "Given version is not on available on Hackage." ++ show givenVersion

upgrade ::
  PackageName ->
  Version ->
  (FilePath, GenericPackageDescription) ->
  IO GenericPackageDescription
upgrade pk latest (_, cabalFile) = do
  case lookupDep cabalFile pk of
    Nothing -> do
      putStrLn $ "No current dependency on: " ++ prettyShow pk
      die $ "Perhaps you want to run: cabal-edit add " ++ prettyShow pk
    Just dep -> do
      case depVerRange dep of
        LaterVersion prev ->
          if prev < latest
            then do
              let ver' = intersectVersionRanges (orLaterVersion prev) (orEarlierVersion latest)
              let dep' = Dependency (depPkgName dep) ver' (depLibraries dep)
              pure $ modifyDep cabalFile pk dep'
            else do
              putStrLn "Previous version is inconsistent, replacing lower bound."
              replaceVersion dep
        OrLaterVersion prev -> do
          let ver' = intersectVersionRanges (orLaterVersion prev) (orEarlierVersion latest)
          let dep' = Dependency (depPkgName dep) ver' (depLibraries dep)
          pure $ modifyDep cabalFile pk dep'
        AnyVersion -> replaceVersion dep
        WildcardVersion _ -> replaceVersion dep
        ThisVersion _ -> replaceVersion dep
        OrEarlierVersion _ -> replaceVersion dep
        EarlierVersion _ -> replaceVersion dep
        VersionRangeParens _ -> replaceVersion dep
        IntersectVersionRanges lower _ -> do
          if extractLower lower < latest
            then do
              let ver' = intersectVersionRanges lower (orEarlierVersion latest)
              let dep' = Dependency (depPkgName dep) ver' (depLibraries dep)
              pure $ modifyDep cabalFile pk dep'
            else replaceVersion dep
        UnionVersionRanges _ _ -> replaceVersion dep
        MajorBoundVersion prev -> do
          if prev < latest
            then do
              let ver' = intersectVersionRanges (orLaterVersion prev) (orEarlierVersion latest)
              let dep' = Dependency (depPkgName dep) ver' (depLibraries dep)
              pure $ modifyDep cabalFile pk dep'
            else replaceVersion dep
  where
    extractLower :: VersionRange -> Version
    extractLower (LaterVersion ver) = ver
    extractLower (OrLaterVersion ver) = ver
    extractLower _ = version0
    replaceVersion dep = do
      let dep' = Dependency (depPkgName dep) (majorBoundVersion latest) (depLibraries dep)
      pure $ modifyDep cabalFile pk dep'

remove ::
  PackageName ->
  (FilePath, GenericPackageDescription) ->
  IO GenericPackageDescription
remove pk (_, cabalFile) = do
  case lookupDep cabalFile pk of
    Nothing -> die $ "No dependency on:  " ++ show pk
    Just _ -> pure $ deleteDep cabalFile pk

addVer ::
  (Version -> VersionRange) ->
  Version ->
  (FilePath, GenericPackageDescription) ->
  Dependency ->
  IO GenericPackageDescription
addVer f givenVersion (fname, cabalFile) dep = do
  let pk = depPkgName dep
  verMap <- cacheDeps
  let dependency = Dependency pk (f givenVersion) (Set.singleton defaultLibName)
  case Map.lookup pk verMap of
    Nothing -> die $ "No such named: " ++ show pk
    Just vers ->
      if givenVersion `elem` vers
        then do
          putStrLn $ "Adding explicit dependency: " ++ prettyShow dependency ++ " to " ++ takeFileName fname
          let dep' = Dependency (depPkgName dep) (majorBoundVersion givenVersion) (depLibraries dep)
          pure $ modifyDep cabalFile pk dep'
        else die $ "Given version is not on available on Hackage." ++ show givenVersion

-------------------------------------------------------------------------------
-- Version Cache
-------------------------------------------------------------------------------

cacheFile :: FilePath
cacheFile = ".cabal-cache.db"

cacheDeps :: IO (Map PackageName [Version])
cacheDeps = do
  cache <- cacheDb
  cacheExists <- doesFileExist cache
  if cacheExists
    then do
      dbContents <- BS.readFile cache
      case decode dbContents of
        Left _ -> die "Corrupted cabal cache file. Run 'cabal-edit rebuild'."
        Right db -> pure db
    else do
      putStrLn "No cache file found, building from HackageDB."
      buildCache

buildCache :: IO (Map PackageName [Version])
buildCache = do
  cache <- cacheDb
  hdb <- hackageTarball
  now <- getCurrentTime
  tdb <- U.readTarball (Just now) hdb
  vers <- forM (Map.toList tdb) $ \(pk, pdata) -> do
    let verMap = Map.keys (P.parsePackageData pk pdata)
    pure (pk, verMap)
  let db = Map.fromList vers
  BS.writeFile cache (encode db)
  pure db

cacheDb :: IO FilePath
cacheDb = do
  home <- getHomeDirectory
  cabalExists <- doesDirectoryExist (home </> ".cabal")
  if cabalExists
    then pure (home </> ".cabal" </> cacheFile)
    else die "No ~/.cabal directory found. Is cabal installed?"

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

listCmd :: String -> IO ()
listCmd packName = do
  pk <- case (simpleParsec packName :: Maybe PackageName) of
    Nothing -> die "Invalid package name."
    Just pk -> pure pk
  verMap <- cacheDeps
  vers <- case Map.lookup pk verMap of
    Nothing -> die $ "No such named: " ++ show pk
    Just vers -> pure (sort vers)
  mapM_ (putStrLn . prettyShow) vers

addCmd :: String -> IO ()
addCmd packName = do
  dep <- case (simpleParsec packName :: Maybe Dependency) of
    Nothing -> die "Invalid dependency version number."
    Just dep -> pure dep
  (fname, cabalFile) <- getCabal
  cabalFile' <- add dep (fname, cabalFile)
  --hasLib cabalFile
  writeGenericPackageDescription fname cabalFile'

upgradeCmd :: String -> IO ()
upgradeCmd packName = do
  pk <- case (simpleParsec packName :: Maybe PackageName) of
    Nothing -> die "Invalid package name."
    Just pk -> pure pk
  verMap <- cacheDeps
  latestVer <- case Map.lookup pk verMap of
    Nothing -> die $ "No such named: " ++ show pk
    Just vers -> pure (maximum vers)
  (fname, cabalFile) <- getCabal
  --hasLib cabalFile
  case lookupDep cabalFile pk of
    Nothing -> die $ "No current dependency on: " ++ show pk
    Just _ -> do
      let ver' = majorUpperBound latestVer
      putStrLn $ "Upgrading bounds for " ++ prettyShow pk ++ " to " ++ prettyShow ver'
      --traverse (putStrLn . prettyShow) (depMap cabalFile)
      cabalFile' <- upgrade pk ver' (fname, cabalFile)
      writeGenericPackageDescription fname cabalFile'

upgradeAllCmd :: IO ()
upgradeAllCmd = do
  verMap <- cacheDeps
  (fname, cabalFile) <- getCabal
  let pks = fmap depPkgName (getDeps cabalFile)
  forM_ pks $ \pk -> do
    latestVer <- case Map.lookup pk verMap of
      Nothing -> die $ "No such named: " ++ show pk
      Just vers -> pure (maximum vers)
    let ver' = majorUpperBound latestVer
    putStrLn $ "Upgrading bounds for " ++ prettyShow pk ++ " to " ++ prettyShow ver'
    cabalFile <- readGenericPackageDescription normal fname
    cabalFile' <- upgrade pk ver' (fname, cabalFile)
    writeGenericPackageDescription fname cabalFile'

removeCmd :: String -> IO ()
removeCmd packName = do
  pk <- case (simpleParsec packName :: Maybe PackageName) of
    Nothing -> die "Invalid package name."
    Just pk -> pure pk
  (fname, cabalFile) <- getCabal
  case lookupDep cabalFile pk of
    Nothing -> die $ "No current dependency on: " ++ show pk
    Just _ -> do
      putStrLn $ "Removing dependency on " ++ prettyShow pk
      cabalFile' <- remove pk (fname, cabalFile)
      writeGenericPackageDescription fname cabalFile'

rebuildCmd :: IO ()
rebuildCmd = buildCache >> putStrLn "Done."

extensionsCmd :: IO ()
extensionsCmd = do
  (fname, cabalFile) <- getCabal
  let extensions = fmap defaultExtensions (buildInfo cabalFile)
  case extensions of
    Nothing -> putStrLn $ "No default extensions in " ++ takeFileName fname
    Just exts -> mapM_ (putStrLn . showExt) exts
  where
    showExt ext = "{-# LANGUAGE " ++ prettyShow ext ++ " #-}"

formatCmd :: IO ()
formatCmd = do
  (fname, cabalFile) <- getCabal
  putStrLn $ "Formatting: " ++ takeFileName fname
  writeGenericPackageDescription fname cabalFile

getCabal :: IO (FilePath, GenericPackageDescription)
getCabal = do
  cabalFiles <- glob "*.cabal"
  case cabalFiles of
    [] -> die "No cabal file found in current directory."
    [fname] -> do
      pkg <- readGenericPackageDescription normal fname
      pure (fname, pkg)
    _ -> die "Multiple cabal-files found."

-------------------------------------------------------------------------------
-- Orphan Sinbin
-------------------------------------------------------------------------------

instance Store PackageName

instance Store ShortText

instance Store Version

-------------------------------------------------------------------------------
-- Options Parsing
-------------------------------------------------------------------------------

data Cmd
  = Add String
  | List String
  | Upgrade String
  | UpgradeAll
  | Remove String
  | Format
  | Rebuild
  | Extensions
  deriving (Eq, Show)

completerPacks :: IO [String]
completerPacks = do
  db <- cacheDeps
  pure (unPackageName <$> Map.keys db)

addParse :: [String] -> Parser Cmd
addParse localPackages = Add <$> argument str (metavar "PACKAGE" <> completeWith localPackages)

listParse :: [String] -> Parser Cmd
listParse localPackages = List <$> argument str (metavar "PACKAGE" <> completeWith localPackages)

upgradeParse :: [String] -> Parser Cmd
upgradeParse localPackages = Upgrade <$> argument str (metavar "PACKAGE" <> completeWith localPackages)

removeParse :: [String] -> Parser Cmd
removeParse localPackages = Remove <$> argument str (metavar "PACKAGE" <> completeWith localPackages)

opts :: [String] -> Parser Cmd
opts localPackages =
  subparser $
    mconcat
      [ command "add" (info (addParse localPackages) (progDesc "Add dependency to cabal file.")),
        command "list" (info (listParse localPackages) (progDesc "List available versions from Hackage.")),
        command "upgrade" (info (upgradeParse localPackages) (progDesc "Upgrade bounds for given package.")),
        command "remove" (info (removeParse localPackages) (progDesc "Remove a given package.")),
        command "rebuild" (info (pure Rebuild) (progDesc "Rebuild cache.")),
        command "upgradeall" (info (pure UpgradeAll) (progDesc "Upgrade all dependencies.")),
        command "format" (info (pure Format) (progDesc "Format cabal file.")),
        command "extensions" (info (pure Extensions) (progDesc "List all default language extensions pragmas."))
      ]

main :: IO ()
main = do
  comps <- completerPacks
  let options = info (opts comps <**> helper) idm
  cmd <- customExecParser p options
  case cmd of
    Add dep -> addCmd dep
    List dep -> listCmd dep
    Upgrade dep -> upgradeCmd dep
    Remove dep -> removeCmd dep
    Format -> formatCmd
    Rebuild -> rebuildCmd
    Extensions -> extensionsCmd
    UpgradeAll -> upgradeAllCmd
  where
    p = prefs showHelpOnEmpty
