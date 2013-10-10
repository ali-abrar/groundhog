{-# LANGUAGE GADTs, TypeFamilies, TemplateHaskell, QuasiQuotes, FlexibleInstances, StandaloneDeriving #-}
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Database.Groundhog.Core (UniqueMarker)
import Database.Groundhog.TH
import Database.Groundhog.Sqlite

data Artist = Artist { artistName :: String } deriving (Eq, Show)
data Album  = Album  { albumName :: String} deriving (Eq, Show)
-- We cannot use regular deriving because when it works, the Key Eq and Show instances for (DefaultKey Album) are not created yet
data Track  = Track  { albumTrack :: DefaultKey Album, trackName :: String }
deriving instance Eq Track
deriving instance Show Track

-- It is phantom datatype of the ArtistName unique key. Usually they are generated by Template Haskell, but we define it manually to use in ArtistAlbum datatype
data ArtistName v where
  ArtistName :: ArtistName (UniqueMarker Artist)

-- Many-to-many relation.
data ArtistAlbum = ArtistAlbum {artist :: Key Artist (Unique ArtistName), album :: DefaultKey Album }
deriving instance Eq ArtistAlbum
deriving instance Show ArtistAlbum

mkPersist defaultCodegenConfig [groundhog|
definitions:
  - entity: Artist
    autoKey:
      constrName: AutoKey
      default: false # Defines if this key is used when an entity is stored directly, for example, data Ref = Ref Artist
    keys:
      - name: ArtistName
        default: true
    constructors:
      - name: Artist
        uniques:
          - name: ArtistName
            # Optional parameter type can be constraint (by default), index, or primary
            type: constraint
            fields: [artistName]
  - entity: Album
  - entity: Track
    constructors:
      - name: Track
        fields:
          - name: albumTrack
  # Configure actions on parent table changes
            reference:
              onDelete: cascade
              onUpdate: restrict
  - entity: ArtistAlbum
    autoKey: null # Disable creation of the autoincrement integer key
    keys:
      - name: ArtistAlbumKey
        default: true
    constructors:
      - name: ArtistAlbum
        uniques:
          - name: ArtistAlbumKey
            fields: [artist, album]
|]

main :: IO ()
main = withSqliteConn ":memory:" $ runDbConn $ do
  let artists = [Artist "John Lennon", Artist "George Harrison"]
      imagineAlbum = Album "Imagine"
  runMigration defaultMigrationLogger $ do
    migrate (undefined :: ArtistAlbum)
    migrate (undefined :: Track)
  mapM_ insert artists

  imagineKey <- insert imagineAlbum
  let tracks = map (Track imagineKey) ["Imagine", "Crippled Inside", "Jealous Guy", "It's So Hard", "I Don't Want to Be a Soldier, Mama, I Don't Want to Die", "Gimme Some Truth", "Oh My Love", "How Do You Sleep?", "How?", "Oh Yoko!"]
  mapM_ insert tracks
  mapM_ (\artist -> insert $ ArtistAlbum (extractUnique artist) imagineKey) artists
  -- print first 3 tracks from any album with John Lennon
  [albumKey'] <- project AlbumField $ (ArtistField ==. ArtistNameKey "John Lennon") `limitTo` 1
  -- order by primary key
  tracks' <- select $ (AlbumTrackField ==. albumKey') `orderBy` [Desc AutoKeyField] `limitTo` 3
  liftIO $ print tracks'