module Hailstorm.Runner (localRunner) where

import Control.Concurrent
import Control.Monad
import Data.Maybe
import GHC.Conc (threadStatus, ThreadStatus(..))
import Hailstorm.Partition
import Hailstorm.Payload
import Hailstorm.Processor.Runner
import Hailstorm.Topology
import Hailstorm.UserFormula
import Hailstorm.ZKCluster
import System.Exit
import System.IO

import qualified Data.Map as Map

threadDead :: ThreadId -> IO Bool
threadDead = fmap (\x -> x == ThreadDied || x == ThreadFinished) . threadStatus

-- TODO: this needs to be cleaned out. Currently hardcoded.
-- TODO: I'm making this hardcoded topology-specific pending
-- discussion of new interface method to add to Topology
localRunner :: (Show k, Show v, Read k, Read v)
            => ZKOptions
            -> HardcodedTopology
            -> UserFormula k v
            -> FilePath
            -> String
            -> IO ()
localRunner zkOpts topology formula filename ispout = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    quietZK

    putStrLn "Running in local mode..."

    negotiatorId <- forkOS $ runNegotiator zkOpts topology
    putStrLn $ "Spawned negotiator" ++ show negotiatorId
    threadDelay 1000000

    let runDownstreamThread processorTuple = do
            consumerId <- forkOS $ runDownstream zkOpts processorTuple
                topology formula
            putStrLn $ "Spawned sink " ++ show consumerId
            return consumerId
    consumerIds <- mapM runDownstreamThread $ (Map.keys . addresses) topology
    threadDelay 1000000

    let f = partitionFromFile filename
    spoutId <- forkOS $ runSpoutFromProducer zkOpts (ispout, 0) topology formula
      (partitionToPayloadProducer formula f)

    let baseThreads = [(negotiatorId, "Negotiator"), (spoutId, "Spout")]
        consumerThreads = map (\tid -> (tid, show tid)) consumerIds
        threadToName = Map.fromList $ baseThreads ++ consumerThreads

    forever $ do 
        mapM_ (\tid -> do
                dead <- threadDead tid
                when dead $ do
                    hPutStrLn stderr $ fromJust (Map.lookup tid threadToName) ++ " thread terminated... shutting down"
                    exitWith $ ExitFailure 1
              ) (Map.keys threadToName)
        threadDelay $ 1000 * 1000