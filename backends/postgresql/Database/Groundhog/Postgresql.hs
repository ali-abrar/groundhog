{-# LANGUAGE ScopedTypeVariables, FlexibleInstances #-}
module Database.Groundhog.Postgresql
    ( withPostgresqlPool
    , withPostgresqlConn
    , runPostgresqlPool
    , runPostgresqlConn
    , Postgresql
    , module Database.Groundhog
    ) where

import Database.Groundhog
import Database.Groundhog.Core
import Database.Groundhog.Generic
import Database.Groundhog.Generic.Sql

import qualified Database.HDBC as H
import qualified Database.HDBC.PostgreSQL as H

import Control.Exception.Control (bracket, onException)
import Control.Monad(liftM, forM, (>=>))
import Control.Monad.IO.Control (MonadControlIO)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Class(MonadTrans(..))
import Control.Monad.Trans.Reader(ask)
import Data.Enumerator(Enumerator, Iteratee(..), Stream(..), checkContinue0, (>>==), joinE, runIteratee, continue, concatEnums)
import qualified Data.Enumerator.List as EL
import Data.Int (Int64)
import Data.List (intercalate)
import Data.IORef
import qualified Data.Map as Map
import Data.Pool

import Data.Time.LocalTime (localTimeToUTC, utc)

-- typical operations for connection: OPEN, BEGIN, COMMIT, ROLLBACK, CLOSE
data Postgresql = Postgresql H.Connection (IORef (Map.Map String H.Statement))

instance MonadControlIO m => PersistBackend (DbPersist Postgresql m) where
  {-# SPECIALIZE instance PersistBackend (DbPersist Postgresql IO) #-}
  insert v = insert' v
  insertBy v = insertBy' v
  replace k v = replace' k v
  selectEnum cond ords limit offset = selectEnum' cond ords limit offset
  selectAllEnum = selectAllEnum'
  select cond ords limit offset = select' cond ords limit offset
  selectAll = selectAll'
  get k = get' k
  update upds cond = update' upds cond
  delete cond = delete' cond
  deleteByKey k = deleteByKey' k
  count cond = count' cond
  countAll fakeV = countAll' fakeV
  migrate fakeV = migrate' fakeV

  executeRaw False query ps = executeRaw' query ps
  executeRaw True query ps = executeRawCached' query ps
  queryRaw False query ps f = queryRaw' query ps f
  queryRaw True query ps f = queryRawCached' query ps f

  insertList l = insertList' l
  getList k = getList' k
  insertTuple t ts = insertTuple' t ts
  getTuple t k = getTuple' t k

--{-# SPECIALIZE withPostgresqlPool :: String -> Int -> (Pool Postgresql -> IO a) -> IO a #-}
withPostgresqlPool :: MonadControlIO m
               => String
               -> Int -- ^ number of connections to open
               -> (Pool Postgresql -> m a)
               -> m a
withPostgresqlPool s = createPool (open' s) close'

{-# SPECIALIZE withPostgresqlConn :: String -> (Postgresql -> IO a) -> IO a #-}
{-# INLINE withPostgresqlConn #-}
withPostgresqlConn :: MonadControlIO m
               => String
               -> (Postgresql -> m a)
               -> m a
withPostgresqlConn s = bracket (liftIO $ open' s) (liftIO.close')

{-# SPECIALIZE runPostgresqlPool :: DbPersist Postgresql IO a -> Pool Postgresql -> IO a #-}
runPostgresqlPool :: MonadControlIO m => DbPersist Postgresql m a -> Pool Postgresql -> m a
runPostgresqlPool = flip withPool' . runPostgresqlConn

{-# SPECIALIZE runPostgresqlConn :: DbPersist Postgresql IO a -> Postgresql -> IO a #-}
{-# INLINE runPostgresqlConn #-}
runPostgresqlConn :: MonadControlIO m => DbPersist Postgresql m a -> Postgresql -> m a
runPostgresqlConn f conn@(Postgresql c _) = do
  x <- onException (runDbPersist f conn) (liftIO $ H.rollback c)
  liftIO $ H.commit c
  return x

open' :: String -> IO Postgresql
open' s = do
  conn <- H.connectPostgreSQL s
  cache <- newIORef Map.empty
  return $ Postgresql conn cache

close' :: Postgresql -> IO ()
close' (Postgresql conn _) = H.disconnect conn

{- ********************RULES******************** --
For type with a single constructor, a single table is created.
TABLE Entity(id, [fields])
If constructor has no fields, then ????

For type with a multiple constructors, the main table is created.
TABLE(id, discriminator)
where discriminator is defined by constructor.
Each constructor has its table, where id is the same as in 
TABLE EntityConstructor2(id, [fields])

In Java Hibernate each class member of list type is stored in a separate table
TABLE Student$Phones(studentId, phone)
Here we can use triggers to automatically remove list after Student removal.
However, toPersistValue :: a -> DbPersist conn m () becomes impossible because we must know container id

We can either follow this scheme or store same type lists from different types in one table
TABLE List$Int(id, value)

-- ********************************************* --}
migrate' :: (PersistEntity v, MonadControlIO m) => v -> Migration (DbPersist Postgresql m)
migrate' = migrateRecursively migE migT migL where
  migE e = do
    let name = getEntityName e
    let constrs = constructors e
    let mainTableQuery = "CREATE TABLE " ++ escape name ++ " (id INTEGER PRIMARY KEY, discr INTEGER NOT NULL)"
    if isSimple constrs
      then do
        x <- checkTable name
        -- check whether the table was created for multiple constructors before
        case x of
          Just sql | sql == mainTableQuery -> do
            return $ Left ["Datatype with multiple constructors was truncated to one constructor. Manual migration required. Datatype: " ++ name]
          _ -> liftM snd $ migConstrAndTrigger True name $ head constrs
      else do
        mainsql <- checkTable name
        let constrTable c = name ++ [defDelim] ++ constrName c
        res <- mapM (\c -> migConstrAndTrigger False name c) constrs
        case mainsql of
          Nothing -> do
            -- no constructor tables can exist if there is no main data table
            let orphans = filter fst res
            return $ if null orphans
              then mergeMigrations $ Right [(False, mainTableQuery)]:map snd res
              else Left $ foldl (\l (_, c) -> ("Orphan constructor table found: " ++ constrTable c):l) [] $ filter (fst.fst) $ zip res constrs
          Just sql -> do
            if sql == mainTableQuery
              then do -- the datatype had also many constructors before
-- check whether any new constructors appeared and increment older discriminators, which were shifted by newer constructors inserted not in the end
                return $ if any (not.fst) res
                  then Left ["Migration with constructors addition will be implemented soon. Datatype: " ++ name]
                  else mergeMigrations $ map snd res
              else do
                return $ Left ["Migration from one constructor to many will be implemented soon. Datatype: " ++ name]
            
  -- we don't need any escaping because tuple table name and fields are always valid
  migT n ts = do
    let name = intercalate "$" $ ("Tuple" ++ show n ++ "$") : map getName ts
    let fields = zipWith (\i t -> ("val" ++ show i, t)) [0::Int ..] ts
    (_, trigger) <- migTriggerOnDelete name $ mkDeletesOnDelete fields
    x <- checkTable name
    let fields' = concatMap (\(s, t) -> sqlColumn s (getType t)) fields
    let query = "CREATE TABLE " ++ name ++ " (id INTEGER PRIMARY KEY" ++ fields' ++ ")"
    return $ case x of
      Nothing  -> mergeMigrations [Right [(False, query)], trigger]
      Just sql -> if sql == query
        then Right []
        else Left ["Tuple table " ++ name ++ " has unexpected structure"]

  -- we should consider storing tuples as is, not their id. For example for [(a, b)] this will prevent many unnecessary queries
  --TODO:finish
  migL t = do
    let mainName = "List$" ++ "$" ++ getName t
    let valuesName = mainName ++ "$" ++ "values"
    let mainQuery = "CREATE TABLE " ++ mainName ++ " (id INTEGER PRIMARY KEY)"
    let valuesQuery = "CREATE TABLE " ++ valuesName ++ " (id INTEGER, ord$ INTEGER NOT NULL" ++ sqlColumn "value" (getType t) ++ ")"
    x <- checkTable mainName
    y <- checkTable valuesName
    (_, triggerMain) <- migTriggerOnDelete mainName ["DELETE FROM " ++ valuesName ++ " WHERE id=old.id;"]
    (_, triggerValues) <- migTriggerOnDelete valuesName $ mkDeletesOnDelete [("value", t)]
    let f name a b = if a /= b then ["List table " ++ name ++ " error. Expected: " ++ a ++ ". Found: " ++ b] else []
    return $ case (x, y) of
      (Nothing, Nothing) -> mergeMigrations [Right [(False, mainQuery), (False, valuesQuery)], triggerMain, triggerValues]
      (Just sql1, Just sql2) -> let errors = f mainName mainQuery sql1 ++ f valuesName valuesQuery sql2
                                in if null errors then Right [] else Left errors
      (_, Nothing) -> Left ["Found orphan main list table " ++ mainName]
      (Nothing, _) -> Left ["Found orphan list values table " ++ valuesName]

migConstrAndTrigger :: MonadControlIO m => Bool -> String -> ConstructorDef -> DbPersist Postgresql m (Bool, SingleMigration)
migConstrAndTrigger simple name constr = do
  let cName = if simple then name else name ++ [defDelim] ++ constrName constr
  (constrExisted, mig) <- migConstr cName constr
  let dels = mkDeletesOnDelete $ constrParams constr
  let allDels = if simple then dels else ("DELETE FROM " ++ escape name ++ " WHERE id=old." ++ constrId ++ ";"):dels
  (triggerExisted, delTrigger) <- migTriggerOnDelete cName allDels
  let updDels = mkDeletesOnUpdate $ constrParams constr
  updTriggers <- mapM (liftM snd . uncurry (migTriggerOnUpdate cName)) updDels
  return $ if constrExisted == triggerExisted || (constrExisted && null allDels)
    then (constrExisted, mergeMigrations ([mig, delTrigger] ++ updTriggers))
    -- this can happen when an ephemeral field was added. Consider doing something else except throwing an error
    else (constrExisted, Left ["Trigger and constructor table must exist together: " ++ cName])

migConstr :: MonadControlIO m => String -> ConstructorDef -> DbPersist Postgresql m (Bool, SingleMigration)
migConstr name constr = do
  let fields = constrParams constr
  let uniques = constrConstrs constr
  let query = "CREATE TABLE " ++ escape name ++ " (" ++ constrId ++ " INTEGER PRIMARY KEY" ++ concatMap (\(n, t) -> sqlColumn n (getType t)) fields ++ concatMap sqlUnique uniques ++ ")"
  x <- checkTable name
  return $ case x of
    Nothing  -> (False, Right [(False, query)])
    Just sql -> (True, if sql == query
      then Right []
      else Left ["Constructor table must be altered: " ++ name])

-- it handles only delete operations. So far when list or tuple replace is not allowed, it is ok
migTriggerOnDelete :: MonadControlIO m => String -> [String] -> DbPersist Postgresql m (Bool, SingleMigration)
migTriggerOnDelete name deletes = do
  let query = "CREATE TRIGGER " ++ escape name ++ " DELETE ON " ++ escape name ++ " BEGIN " ++ concat deletes ++ "END"
  x <- checkTrigger name
  return $ case x of
    Nothing | null deletes -> (False, Right [])
    Nothing -> (False, Right [(False, query)])
    Just sql -> (True, if null deletes -- remove old trigger if a datatype earlier had fields of ephemeral types
      then Right [(False, "DROP TRIGGER " ++ escape name)]
      else if sql == query
        then Right []
        -- this can happen when a field was added or removed. Consider trigger replacement.
        else Left ["The trigger " ++ name ++ " is different from expected. Manual migration required.\n" ++ sql ++ "\n" ++ query])
        
-- | Table name and a  list of field names and according delete statements
-- assume that this function is called only for ephemeral fields
migTriggerOnUpdate :: MonadControlIO m => String -> String -> String -> DbPersist Postgresql m (Bool, SingleMigration)
migTriggerOnUpdate name fieldName del = do
  let tname = name ++ "$" ++ fieldName
  let query = "CREATE TRIGGER " ++ escape tname ++ " UPDATE OF " ++ escape fieldName ++ " ON " ++ escape name ++ " BEGIN " ++ del ++ "END"
  x <- checkTrigger tname
  return $ case x of
    Nothing -> (False, Right [(False, query)])
    Just sql -> (True, if sql == query
        then Right []
        else Left ["The trigger " ++ tname ++ " is different from expected. Manual migration required.\n" ++ sql ++ "\n" ++ query])

-- on delete removes all ephemeral data
-- TODO: merge several delete queries for a case when a constructor has several fields of the same ephemeral type
mkDeletesOnDelete :: [(String, NamedType)] -> [String]
mkDeletesOnDelete types = map (uncurry delField) ephemerals where
  -- we have the same query structure for tuples and lists
  delField field t = "DELETE FROM " ++ tname ++ " WHERE id=old." ++ escape field ++ ";" where
    tname = getName t
  ephemerals = filter (isEphemeral.snd) types
  
-- on delete removes all ephemeral data
mkDeletesOnUpdate :: [(String, NamedType)] -> [(String, String)]
mkDeletesOnUpdate types = map (uncurry delField) ephemerals where
  -- we have the same query structure for tuples and lists
  delField field t = (field, "DELETE FROM " ++ tname ++ " WHERE id=old." ++ escape field ++ ";") where
    tname = getName t
  ephemerals = filter (isEphemeral.snd) types

isEphemeral :: NamedType -> Bool
isEphemeral a = case getType a of
  DbList _    -> True
  DbTuple _ _ -> True
  _           -> False

checkTrigger :: MonadControlIO m => String -> DbPersist Postgresql m (Maybe String)
checkTrigger = checkSqliteMaster "trigger"

checkTable :: MonadControlIO m => String -> DbPersist Postgresql m (Maybe String)
checkTable = checkSqliteMaster "table"

checkSqliteMaster :: MonadControlIO m => String -> String -> DbPersist Postgresql m (Maybe String)
checkSqliteMaster vtype name = error "checkSqliteMaster" {-do
  let query = "SELECT sql FROM sqlite_master WHERE type = ? AND name = ?"
  x <- queryRawTyped query [DbString] [toPrim vtype, toPrim name] firstRow
  let throwErr = error . ("Unexpected result from sqlite_master: " ++)
  case x of
    Nothing -> return Nothing
    Just [hsql] -> case hsql of
      PersistString sql -> return $ Just sql
      err               -> throwErr $ "column sql is not string: " ++ show err
    Just xs -> throwErr $ "requested 1 column, returned " ++ show xs-}

getStatementCached :: MonadIO m => String -> DbPersist Postgresql m H.Statement
getStatementCached sql = do
  Postgresql conn smap <- DbPersist ask
  liftIO $ do
    smap' <- readIORef smap
    case Map.lookup sql smap' of
      Nothing -> do
        stmt <- H.prepare conn sql
        writeIORef smap (Map.insert sql stmt smap')
        return stmt
      Just stmt -> return stmt

getStatement :: MonadIO m => String -> DbPersist Postgresql m H.Statement
getStatement sql = do
  Postgresql conn _ <- DbPersist ask
  liftIO $ H.prepare conn sql

showSqlType :: DbType -> String
showSqlType DbString = "VARCHAR"
showSqlType DbInt32 = "INT4"
showSqlType DbInt64 = "INT8"
showSqlType DbReal = "DOUBLE PRECISION"
showSqlType DbBool = "BOOLEAN"
showSqlType DbDay = "DATE"
showSqlType DbTime = "TIME"
showSqlType DbDayTime = "TIMESTAMP"
showSqlType DbBlob = "BYTEA"
showSqlType (DbMaybe t) = showSqlType (getType t)
showSqlType (DbList _) = "INTEGER"
showSqlType (DbTuple _ _) = "INTEGER"
showSqlType (DbEntity _) = "INTEGER"

{-
DbMaybe prim -> name type
prim         -> name type NOT NULL
comp         -> name type NOT NULL REFERENCES table
DbMaybe comp -> name type REFERENCES table
-}

sqlColumn :: String -> DbType -> String
sqlColumn name typ = ", " ++ escape name ++ " " ++ showSqlType typ ++ f typ where
  f (DbMaybe t) = g (getType t)
  f t = " NOT NULL" ++ g t
  -- TODO: add references for tuple and list
  g (DbEntity t) = " REFERENCES " ++ escape (getEntityName t)
  g (DbTuple n ts) = " REFERENCES " ++ (intercalate "$" $ ("Tuple" ++ show n ++ "$") : map getName ts)
  g (DbList t) = " REFERENCES " ++ "List$$" ++ getName t
  g _ = ""

sqlUnique :: Constraint -> String
sqlUnique (cname, cols) = concat
    [ ", CONSTRAINT "
    , escape cname
    , " UNIQUE ("
    , intercalate "," $ map escape cols
    , ")"
    ]

{-# SPECIALIZE insert' :: PersistEntity v => v -> DbPersist Postgresql IO (Key v) #-}
{-# INLINE insert' #-}
insert' :: (PersistEntity v, MonadControlIO m) => v -> DbPersist Postgresql m (Key v)
insert' v = do
  -- constructor number and the rest of the field values
  vals <- toPersistValues v
  let e = entityDef v
  let name = getEntityName e
  let constructorNum = fromPrim (head vals)

  if isSimple (constructors e)
    then do
      let constr = head $ constructors e
      let query = insertIntoConstructorTable False name constr
      executeRaw True query (tail vals)
      rowid <- getLastInsertRowId
      return $ Key rowid
    else do
      let constr = constructors e !! constructorNum
      let cName = name ++ [defDelim] ++ constrName constr
      let query = "INSERT INTO " ++ escape name ++ "(discr)VALUES(?)"
      executeRaw True query $ take 1 vals
      rowid <- getLastInsertRowId
      let cQuery = insertIntoConstructorTable True cName constr
      executeRaw True cQuery $ PersistInt64 rowid:(tail vals)
      return $ Key rowid

-- in Sqlite we can insert null to the id column. If so, id will be generated automatically
insertIntoConstructorTable :: Bool -> String -> ConstructorDef -> String
insertIntoConstructorTable withId tName c = "INSERT INTO " ++ escape tName ++ "(" ++ fieldNames ++ ")VALUES(" ++ placeholders ++ ")" where
  fieldNames   = intercalate "," $ (if withId then (constrId:) else id) $ map (escape.fst) (constrParams c)
  placeholders = intercalate "," $ (if withId then ("?":) else id) $ map (const "?") (constrParams c)

{-# SPECIALIZE insertBy' :: PersistEntity v => v -> DbPersist Postgresql IO (Either (Key v) (Key v)) #-}
insertBy' :: (MonadControlIO m, PersistEntity v) => v -> DbPersist Postgresql m (Either (Key v) (Key v))
insertBy' v = do
  let e = entityDef v
  let name = getEntityName e

  let constraints = getConstraints v
  let constructorNum = fst constraints
  let constraintFields = map snd $ snd constraints
  let constrCond = intercalate " OR " $ map (intercalate " AND " . map (\(fname, _) -> escape fname ++ "=?")) constraintFields

  let ifAbsent tname ins = if null constraintFields
       then liftM (Right . Key) ins
       else do
         let query = "SELECT " ++ constrId ++ " FROM " ++ escape tname ++ " WHERE " ++ constrCond
         x <- queryRawTyped query [DbInt64] (concatMap (map snd) constraintFields) firstRow
         case x of
           Nothing  -> liftM (Right . Key) ins
           Just [k] -> return $ Left $ fromPrim k
           Just xs  -> fail $ "unexpected query result: " ++ show xs

  if isSimple (constructors e)
    then do
      let constr = head $ constructors e
      ifAbsent name $ do
        let query = insertIntoConstructorTable False name constr
        vals <- toPersistValues v
        executeRaw True query (tail vals)
        getLastInsertRowId
    else do
      let constr = constructors e !! constructorNum
      let cName = name ++ [defDelim] ++ constrName constr
      ifAbsent cName $ do
        let query = "INSERT INTO " ++ escape name ++ "(discr)VALUES(?)"
        vals <- toPersistValues v
        executeRaw True query $ take 1 vals
        rowid <- getLastInsertRowId
        let cQuery = insertIntoConstructorTable True cName constr
        executeRaw True cQuery $ PersistInt64 rowid :(tail vals)
        return rowid

replace' :: (MonadControlIO m, PersistEntity v) => Key v -> v -> DbPersist Postgresql m ()
replace' k v = do
  vals <- toPersistValues v
  let e = entityDef v
  let name = getEntityName e
  let constructorNum = fromPrim (head vals)
  let constr = constructors e !! constructorNum

  let upds = intercalate "," $ map (\f -> escape (fst f) ++ "=?") $ constrParams constr
  let mkQuery tname = "UPDATE " ++ escape tname ++ " SET " ++ upds ++ " WHERE " ++ constrId ++ "=?"

  if isSimple (constructors e)
    then executeRaw True (mkQuery name) (tail vals ++ [toPrim k])
    else do
      let query = "SELECT discr FROM " ++ escape name ++ " WHERE id=?"
      x <- queryRawTyped query [DbInt32] [toPrim k] (firstRow >=> return.fmap (fromPrim . head))
      case x of
        Just discr -> do
          let cName = name ++ [defDelim] ++ constrName constr

          if discr == constructorNum
            then executeRaw True (mkQuery cName) (tail vals ++ [toPrim k])
            else do
              let insQuery = insertIntoConstructorTable True cName constr
              executeRaw True insQuery (toPrim k:tail vals)

              let oldCName = name ++ [defDelim] ++ constrName (constructors e !! discr)
              let delQuery = "DELETE FROM " ++ escape oldCName ++ " WHERE " ++ constrId ++ "=?"
              executeRaw True delQuery [toPrim k]

              -- UGLY: reinsert entry with a new discr to the main table after it was deleted by a trigger.
              let reInsQuery = "INSERT INTO " ++ escape name ++ "(id,discr)VALUES(?,?)"
              executeRaw True reInsQuery [toPrim k, head vals]
        Nothing -> return ()

-- | receives constructor number and row of values from the constructor table
mkEntity :: (PersistEntity v, PersistBackend m) => Int -> [PersistValue] -> m (Key v, v)
mkEntity i (k:xs) = fromPersistValues (toPrim i:xs) >>= \v -> return (fromPrim k, v)
mkEntity _ [] = error "Unable to create entity. No values supplied"

selectEnum' :: (MonadControlIO m, PersistEntity v, Constructor c) => Cond v c -> [Order v c] -> Int -> Int -> Enumerator (Key v, v) (DbPersist Postgresql m) a
selectEnum' (cond :: Cond v c) ords limit offset = start where
  start = if isSimple (constructors e)
    then joinE (queryEnum (mkQuery name) binds) (EL.mapM (mkEntity 0))
    else let
      query = mkQuery $ name ++ [defDelim] ++ constrName constr
      in joinE (queryEnum query binds) (EL.mapM (mkEntity $ constrNum constr))

  e = entityDef (undefined :: v)
  orders = renderOrders escape ords
  name = getEntityName e
  (lim, limps) = case (limit, offset) of
        (0, 0) -> ("", [])
        (0, o) -> (" LIMIT -1 OFFSET ?", [toPrim o])
        (l, 0) -> (" LIMIT ?", [toPrim l])
        (l, o) -> (" LIMIT ? OFFSET ?", [toPrim l, toPrim o])
  (conds, condps) = renderCond' cond
  mkQuery tname = "SELECT * FROM " ++ escape tname ++ " WHERE " ++ (conds . orders $ lim)
  binds = condps limps
  constr = (constructors e) !! phantomConstrNum (undefined :: c)
  types = DbInt64:getConstructorTypes constr

selectAllEnum' :: forall m v a.(MonadControlIO m, PersistEntity v) => Enumerator (Key v, v) (DbPersist Postgresql m) a
selectAllEnum' = start where
  start = if isSimple (constructors e)
    then let
      query = "SELECT * FROM " ++ escape name
      types = DbInt64:(getConstructorTypes $ head $ constructors e)
      in joinE (queryEnum query []) (EL.mapM (mkEntity 0))
    else concatEnums $ zipWith q [0..] (constructors e) where
      q cNum constr = let
        cName = name ++ [defDelim] ++ constrName constr
        query = "SELECT * FROM " ++ escape cName
        types = DbInt64:getConstructorTypes constr
        in joinE (queryEnum query []) (EL.mapM (mkEntity cNum))

  e = entityDef (undefined :: v)
  name = getEntityName e

-- unfortunately, running consume on Enumerator is ~50% slower. So, lets duplicate the code
select' :: (MonadControlIO m, PersistEntity v, Constructor c) => Cond v c -> [Order v c] -> Int -> Int -> DbPersist Postgresql m [(Key v, v)]
select' (cond :: Cond v c) ords limit offset = start where
  start = if isSimple (constructors e)
    then doSelectQuery (mkQuery name) 0
    else let
      cName = name ++ [defDelim] ++ constrName constr
      in doSelectQuery (mkQuery cName) $ constrNum constr

  e = entityDef (undefined :: v)
  orders = renderOrders escape ords
  name = getEntityName e
  (lim, limps) = case (limit, offset) of
        (0, 0) -> ("", [])
        (0, o) -> (" LIMIT -1 OFFSET ?", [toPrim o])
        (l, 0) -> (" LIMIT ?", [toPrim l])
        (l, o) -> (" LIMIT ? OFFSET ?", [toPrim l, toPrim o])
  (conds, condps) = renderCond' cond
  mkQuery tname = "SELECT * FROM " ++ escape tname ++ " WHERE " ++ (conds . orders $ lim)
  doSelectQuery query cNum = queryRawTyped query types binds $ mapAllRows (mkEntity cNum)
  binds = condps limps
  constr = constructors e !! phantomConstrNum (undefined :: c)
  types = DbInt64:getConstructorTypes constr

selectAll' :: forall m v.(MonadControlIO m, PersistEntity v) => DbPersist Postgresql m [(Key v, v)]
selectAll' = start where
  start = if isSimple (constructors e)
    then let
      query = "SELECT * FROM " ++ escape name
      types = DbInt64:(getConstructorTypes $ head $ constructors e)
      in queryRawTyped query types [] $ mapAllRows (mkEntity 0)
    else liftM concat $ forM (zip [0..] (constructors e)) $ \(i, constr) -> do
        let cName = name ++ [defDelim] ++ constrName constr
        let query = "SELECT * FROM " ++ escape cName
        let types = DbInt64:getConstructorTypes constr
        queryRawTyped query types [] $ mapAllRows (mkEntity i)

  e = entityDef (undefined :: v)
  name = getEntityName e

{-
insertList :: PersistField a => [a] -> DbPersist conn m Int64
insertList xs = do
  xs' <- mapM toPersistValue xs
  let name = persistName xs
  let query = "INSERT INTO " ++ name ++ " ("
  getStatement 
-}

insertTuple' :: MonadIO m => NamedType -> [PersistValue] -> DbPersist Postgresql m Int64
insertTuple' t vals = do
  let name = getName t
  let (DbTuple _ ts) = getType t
  let fields = map (\i -> "val" ++ show i) [0 .. length ts - 1] 
  let query = "INSERT INTO " ++ name ++ " (" ++ intercalate ", " fields ++ ")VALUES(" ++ intercalate ", " (replicate (length ts) "?") ++ ")"
  executeRawCached' query vals
  getLastInsertRowId

getTuple' :: MonadControlIO m => NamedType -> Int64 -> DbPersist Postgresql m [PersistValue]
getTuple' t k = do
  let name = getName t
  let (DbTuple _ ts) = getType t
  let query = "SELECT * FROM " ++ name ++ " WHERE id = ?"
  x <- queryRawTyped query (DbInt64:map getType ts) [toPrim k] firstRow
  maybe (fail $ "No tuple with id " ++ show k) (return . tail) x

{-# SPECIALIZE get' :: PersistEntity v => Key v -> DbPersist Postgresql IO (Maybe v) #-}
{-# INLINE get' #-}
get' :: (MonadControlIO m, PersistEntity v) => Key v -> DbPersist Postgresql m (Maybe v)
get' (k :: Key v) = do
  let e = entityDef (undefined :: v)
  let name = getEntityName e
  if isSimple (constructors e)
    then do
      let constr = head $ constructors e
      let query = "SELECT * FROM " ++ escape name ++ " WHERE " ++ constrId ++ "=?"
      x <- queryRawTyped query (DbInt64:getConstructorTypes constr) [toPrim k] firstRow
      case x of
        Just (_:xs) -> liftM Just $ fromPersistValues $ PersistInt64 0:xs
        Just x'    -> fail $ "Unexpected number of columns returned: " ++ show x'
        Nothing -> return Nothing
    else do
      let query = "SELECT discr FROM " ++ escape name ++ " WHERE id=?"
      x <- queryRawTyped query [DbInt64] [toPrim k] firstRow
      case x of
        Just [discr] -> do
          let constructorNum = fromPrim discr
          let constr = constructors e !! constructorNum
          let cName = name ++ [defDelim] ++ constrName constr
          let cQuery = "SELECT * FROM " ++ escape cName ++ " WHERE " ++ constrId ++ "=?"
          x2 <- queryRawTyped cQuery (DbInt64:getConstructorTypes constr) [toPrim k] firstRow
          case x2 of
            Just (_:xs) -> liftM Just $ fromPersistValues $ discr:xs
            Just x2'    -> fail $ "Unexpected number of columns returned: " ++ show x2'
            Nothing     -> fail "Missing entry in constructor table"
        Just x' -> fail $ "Unexpected number of columns returned: " ++ show x'
        Nothing -> return Nothing

update' :: (PersistBackend m, PersistEntity v, Constructor c) => [Update v c] -> Cond v c -> m ()
update' upds (cond :: Cond v c) = do
  let e = entityDef (undefined :: v)
  let name = getEntityName e
  let (conds, condps) = renderCond' cond
  let (upds', ps) = renderUpdates escape upds
  let mkQuery tname = "UPDATE " ++ escape tname ++ " SET " ++ (upds' . (" WHERE " ++) . conds $ "")
  if isSimple (constructors e)
    then executeRaw True (mkQuery name) (ps $ condps [])
    else do
      let cName = name ++ [defDelim] ++ phantomConstrName (undefined :: c)
      executeRaw True (mkQuery cName) (ps $ condps [])

delete' :: (PersistBackend m, PersistEntity v, Constructor c) => Cond v c -> m ()
delete' (cond :: Cond v c) = do
  let e = entityDef (undefined :: v)
  let (conds, condps) = renderCond' cond
  let name = getEntityName e
  if isSimple (constructors e)
    then do
      let query = "DELETE FROM " ++ escape name ++ " WHERE " ++ conds ""
      executeRaw True query (condps [])
    else do
      -- after removal from the constructor table, entry from the main table is removed by trigger
      let cName = name ++ [defDelim] ++ phantomConstrName (undefined :: c)
      let query = "DELETE FROM " ++ escape cName ++ " WHERE " ++ conds ""
      executeRaw True query (condps [])
      
deleteByKey' :: (MonadControlIO m, PersistEntity v) => Key v -> DbPersist Postgresql m ()
deleteByKey' (k :: Key v) = do
  let e = entityDef (undefined :: v)
  let name = getEntityName e
  if isSimple (constructors e)
    then do
      let query = "DELETE FROM " ++ escape name ++ " WHERE id$=?"
      executeRaw True query [toPrim k]
    else do
      let query = "SELECT discr FROM " ++ escape name
      x <- queryRawTyped query [DbInt64] [] firstRow
      case x of
        Just [discr] -> do
          let cName = name ++ [defDelim] ++ constrName (constructors e !! fromPrim discr)
          let cQuery = "DELETE FROM " ++ escape cName ++ " WHERE id$=?"
          executeRaw True cQuery [toPrim k]
        Just xs -> fail $ "requested 1 column, returned " ++ show xs
        Nothing -> return ()

{-# SPECIALIZE count' :: (PersistEntity v, Constructor c) => Cond v c -> DbPersist Postgresql IO Int #-}
count' :: (MonadControlIO m, PersistEntity v, Constructor c) => Cond v c -> DbPersist Postgresql m Int
count' (cond :: Cond v c) = do
  let cName = persistName (undefined :: v) ++ [defDelim] ++ phantomConstrName (undefined :: c)
  let (conds, condps) = renderCond' cond
  let query = "SELECT COUNT(*) FROM " ++ cName ++ " WHERE " ++ conds ""
  x <- queryRawTyped query [DbInt64] (condps []) firstRow
  case x of
    Just [num] -> return $ fromPrim num
    Just xs -> fail $ "requested 1 column, returned " ++ show (length xs)
    Nothing -> fail $ "COUNT returned no rows"

{-# SPECIALIZE countAll' :: PersistEntity v => v -> DbPersist Postgresql IO Int #-}
countAll' :: (MonadControlIO m, PersistEntity v) => v -> DbPersist Postgresql m Int
countAll' (_ :: v) = do
  let name = persistName (undefined :: v)
  let query = "SELECT COUNT(*) FROM " ++ name
  x <- queryRawTyped query [DbInt64] [] firstRow
  case x of
    Just [num] -> return $ fromPrim num
    Just xs -> fail $ "requested 1 column, returned " ++ show (length xs)
    Nothing -> fail $ "COUNT returned no rows"
    
insertList' :: forall m a.(MonadControlIO m, PersistField a) => [a] -> DbPersist Postgresql m Int64
insertList' l = do
  let mainName = "List$$" ++ persistName (undefined :: a)
  executeRaw True ("INSERT INTO " ++ mainName ++ " DEFAULT VALUES") []
  k <- getLastInsertRowId
  let valuesName = mainName ++ "$" ++ "values"
  let query = "INSERT INTO " ++ valuesName ++ "(id,ord$,value)VALUES(?,?,?)"
  let go :: Int -> [a] -> DbPersist Postgresql m ()
      go n (x:xs) = do
       x' <- toPersistValue x
       executeRaw True query [toPrim k, toPrim n, x']
       go (n + 1) xs
      go _ [] = return ()
  go 0 l
  return k
  
getList' :: forall m a.(MonadControlIO m, PersistField a) => Int64 -> DbPersist Postgresql m [a]
getList' k = do
  let mainName = "List$$" ++ persistName (undefined :: a)
  let valuesName = mainName ++ "$" ++ "values"
  queryRawTyped ("SELECT value FROM " ++ valuesName ++ " WHERE id=? ORDER BY ord$") [dbType (undefined :: a)] [toPrim k] $ mapAllRows (fromPersistValue.head)
    
{-# SPECIALIZE getLastInsertRowId :: DbPersist Postgresql IO Int64 #-}
getLastInsertRowId :: MonadIO m => DbPersist Postgresql m Int64
getLastInsertRowId = error "getLastInsertRowId"

constrId :: String
constrId = defId

----------

executeRaw' :: MonadIO m => String -> [PersistValue] -> DbPersist Postgresql m ()
executeRaw' query vals = do
  stmt <- getStatement query
  liftIO $ do
    H.execute stmt (map pToSql vals)
    return ()

{-# SPECIALIZE executeRawCached' :: String -> [PersistValue] -> DbPersist Postgresql IO () #-}
executeRawCached' :: MonadIO m => String -> [PersistValue] -> DbPersist Postgresql m ()
executeRawCached' query vals = do
  stmt <- getStatementCached query
  liftIO $ do
    H.execute stmt (map pToSql vals)
    return ()

queryRaw' :: MonadControlIO m => String -> [PersistValue] -> (RowPopper (DbPersist Postgresql m) -> DbPersist Postgresql m a) -> DbPersist Postgresql m a
queryRaw' query vals f = do
  stmt <- getStatement query
  liftIO $ H.execute stmt (map pToSql vals)
  f $ liftIO $ do
    x <- H.fetchRow stmt
    return $ fmap (map pFromSql) x

queryRawCached' :: MonadControlIO m => String -> [PersistValue] -> (RowPopper (DbPersist Postgresql m) -> DbPersist Postgresql m a) -> DbPersist Postgresql m a
queryRawCached' query vals f = do
  stmt <- getStatementCached query
  liftIO $ H.execute stmt (map pToSql vals)
  f $ liftIO $ do
    x <- H.fetchRow stmt
    return $ fmap (map pFromSql) x

queryRawTyped :: MonadControlIO m => String -> [DbType] -> [PersistValue] -> (RowPopper (DbPersist Postgresql m) -> DbPersist Postgresql m a) -> DbPersist Postgresql m a
queryRawTyped query types vals f = queryRawCached' query vals f

queryEnum :: MonadControlIO m => String -> [PersistValue] -> Enumerator [PersistValue] (DbPersist Postgresql m) b
queryEnum query vals = \step -> do
  stmt <- lift $ getStatementCached query
  liftIO $ H.execute stmt (map pToSql vals)
  let iter = checkContinue0 $ \loop k -> do
      x <- liftIO $ do
        x <- H.fetchRow stmt
        return $ fmap (map pFromSql) x
      maybe (continue k) (\row -> k (Chunks [row]) >>== loop) x
  Iteratee (runIteratee (iter step))

getConstructorTypes :: ConstructorDef -> [DbType]
getConstructorTypes = map (getType.snd) . constrParams

firstRow :: Monad m => RowPopper m -> m (Maybe [PersistValue])
firstRow pop = pop >>= return

mapAllRows :: Monad m => ([PersistValue] -> m a) -> RowPopper m -> m [a]
mapAllRows f pop = go where
  go = pop >>= maybe (return []) (f >=> \a -> liftM (a:) go)

-- It is used to escape table names and columns, which can include only symbols allowed in Haskell datatypes and '$' delimiter. We need it mostly to support names that coincide with SQL keywords
escape :: String -> String
escape s = '\"' : s ++ "\""

renderCond' :: (PersistEntity v, Constructor c) => Cond v c -> RenderS
renderCond' = renderCond escape constrId renderEquals renderNotEquals where
  renderEquals :: (String -> String) -> Expr v c a -> Expr v c a -> RenderS
  renderEquals esc a b = renderExpr esc a <> ((" IS " ++), id) <> renderExpr esc b

  renderNotEquals :: (String -> String) -> Expr v c a -> Expr v c a -> RenderS
  renderNotEquals esc a b = renderExpr esc a <> ((" IS NOT " ++), id) <> renderExpr esc b

isSimple :: [ConstructorDef] -> Bool
isSimple [_] = True
isSimple _   = False

pToSql :: PersistValue -> H.SqlValue
pToSql (PersistString t) = H.SqlString t
pToSql (PersistByteString bs) = H.SqlByteString bs
pToSql (PersistInt64 i) = H.SqlInt64 i
pToSql (PersistDouble d) = H.SqlDouble d
pToSql (PersistBool b) = H.SqlBool b
pToSql (PersistDay d) = H.SqlLocalDate d
pToSql (PersistTimeOfDay t) = H.SqlLocalTimeOfDay t
pToSql (PersistUTCTime t) = H.SqlUTCTime t
pToSql PersistNull = H.SqlNull

pFromSql :: H.SqlValue -> PersistValue
pFromSql (H.SqlString s) = PersistString s
pFromSql (H.SqlByteString bs) = PersistByteString bs
pFromSql (H.SqlWord32 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlWord64 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInt32 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInt64 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInteger i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlChar c) = PersistInt64 $ fromIntegral $ fromEnum c
pFromSql (H.SqlBool b) = PersistBool b
pFromSql (H.SqlDouble b) = PersistDouble b
pFromSql (H.SqlRational b) = PersistDouble $ fromRational b
pFromSql (H.SqlLocalDate d) = PersistDay d
pFromSql (H.SqlLocalTimeOfDay d) = PersistTimeOfDay d
pFromSql (H.SqlUTCTime d) = PersistUTCTime d
pFromSql H.SqlNull = PersistNull
pFromSql (H.SqlLocalTime d) = PersistUTCTime $ localTimeToUTC utc d
pFromSql x = PersistString $ H.fromSql x -- FIXME