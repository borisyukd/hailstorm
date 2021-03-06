module Hailstorm.ZKCluster.MasterState
( MasterState(..)
, injectMasterState
, watchMasterState
, forceSetMasterState
, createMasterState
, getNextSnapshotClock
) where

import Hailstorm.Clock
import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Hailstorm.Error
import Hailstorm.ZKCluster
import Database.Zookeeper as ZK

import qualified System.Log.Logger as L

infoM :: String -> IO ()
infoM = L.infoM "Hailstorm.MasterState"

-- | Master state Zookeeper node.
zkMasterStateNode :: String
zkMasterStateNode = "/master_state"

data MasterState = Unavailable
                 | Initialization
                 | SpoutsRewind Clock
                 | SpoutsPaused
                 | Flowing (Maybe Clock)
                   deriving (Eq, Read, Show)

injectMasterState :: ZK.Zookeeper
                  -> (MVar MasterState -> IO ())
                  -> IO ()
injectMasterState zk action = do
    stateMVar <- newEmptyMVar
    -- Start action on separate thread.
    void <$> forkOS $ action stateMVar
    -- Watch master state and overwrite state MVar on change
    watchMasterState zk $ \et ->
        case et of
            Left e -> throw $ wrapInHSError e UnexpectedZookeeperError
            Right ms -> tryTakeMVar stateMVar >> putMVar stateMVar ms

-- | Set master state, but force IO Exception on failure.
forceSetMasterState :: ZK.Zookeeper
                    -> MasterState
                    -> IO ()
forceSetMasterState zk mState = void <$>
    forceEitherIO UnknownWorkerException $ setMasterState zk mState

-- | Sets state of master node.
setMasterState :: ZK.Zookeeper -> MasterState -> IO (Either ZK.ZKError ZK.Stat)
setMasterState zk ms = do
    r <- ZK.set zk zkMasterStateNode (Just $ serializeZK ms) Nothing
    case r of
        Right _ -> infoM $ "Master state changed: " ++ show ms
        _ -> return ()
    return r

-- | Create an ephemeral master state node on Zookeeper.
createMasterState :: ZK.Zookeeper
                 -> MasterState
                 -> IO (Either ZK.ZKError String)
createMasterState zk ms =
    ZK.create zk zkMasterStateNode
        (Just $ serializeZK ms) ZK.OpenAclUnsafe [ZK.Ephemeral]

-- | Delivers master state change events to the callback. Uses the same thread
-- as was called in with.
watchMasterState :: ZK.Zookeeper
                   -> (Either ZK.ZKError MasterState -> IO ())
                   -> IO ()
watchMasterState zk callback = do
    mVar <- newMVar True
    _ <- ZK.get zk zkMasterStateNode (Just $ watcher mVar)
    watchLoop mVar Unavailable
  where
    watcher mVar _ _ _ _ = putMVar mVar True
    watchLoop mVar lastState = do
        _ <- takeMVar mVar
        me <- ZK.get zk zkMasterStateNode (Just $ watcher mVar)
        case me of
            Left e -> callback (Left e) >> watchLoop mVar lastState
            Right (Just s, _) -> do
                let ms = deserializeZK s :: MasterState
                when (lastState /= ms) (callback $ Right ms)
                watchLoop mVar ms
            _ -> callback (Left ZK.NothingError) >> watchLoop mVar lastState

-- | Returns the desired snapshot clock, if available; otherwise, returns
-- Nothing.
getNextSnapshotClock :: MasterState -> Maybe Clock
getNextSnapshotClock (Flowing (Just clk)) = Just clk
getNextSnapshotClock _ = Nothing
