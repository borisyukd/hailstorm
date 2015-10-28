module Hailstorm.InputSource.KafkaSource
( KafkaOptions(..)
, KafkaSource(..)
, kafkaProducerFromOptions
, partitionProducer'
) where

import Control.Monad
import Control.Exception
import Haskakafka
import Haskakafka.InternalSetup (ConfigOverrides, newKafkaConf, newKafkaTopicConf)
import Haskakafka.InternalRdKafkaEnum (RdKafkaRespErrT(..))
import Hailstorm.Clock
import Hailstorm.InputSource
import Hailstorm.Error
import Pipes

import qualified Data.Map.Strict as Map
import qualified System.Log.Logger as L

errorM :: String -> IO ()
errorM = L.errorM "Hailstorm.InputSource.KafkaSource"

infoM :: String -> IO ()
infoM = L.infoM "Hailstorm.InputSource.KafkaSource"

data KafkaOptions = KafkaOptions 
  { brokerConnectionString :: String
  , topic :: String 
  , defaultKafkaTimeout :: Int
  } deriving (Eq, Show)


partitionProducer' :: KafkaTopic -> Int -> Producer InputTuple IO ()
partitionProducer' = kConsumer 
    where
      kOpts = KafkaOptions "localhost:9092" "test" 60000
      kConsumer kTopic partition = forever $ do
        me <- lift $ consumeMessage kTopic partition (defaultKafkaTimeout kOpts)
        case me of 
          (Left (KafkaResponseError RdKafkaRespErrPartitionEof)) ->
            lift $ infoM $ "End of partition " ++ show partition ++ ": waiting for producer"
          Left e -> 
            lift $ errorM $ "Got error while consuming from Kafka: " ++ show e
          Right m -> do
            yield $ InputTuple (messagePayload m) 
                               (show $ messagePartition m) 
                               (fromIntegral $ messageOffset m)

kafkaProducerFromOptions :: KafkaOptions -> IO (Either HSError (Kafka, KafkaTopic))
kafkaProducerFromOptions kOpts = withKafkaProducer [] [] (brokerConnectionString kOpts) (topic kOpts) $ \kafka kTopic -> return $ Right (kafka, kTopic)

{-
kafkaFromOptions :: KafkaOptions -> KafkaType -> IO (Either HSError (Kafka, KafkaTopic))
kafkaFromOptions kOpts t = do
    kConf <- newKafkaConf
    kTopicConf <- newKafkaTopicConf

    kafka <- newKafka t kConf
    addBrokers kafka $ brokerConnectionString kOpts
    kTopic <- newKafkaTopic kafka (topic kOpts) kTopicConf

    return $ Right (kafka, kTopic)
-}

data KafkaSource = KafkaSource 
  { kafkaOptions :: KafkaOptions
  , kafka :: Kafka
  , kTopic :: KafkaTopic
  } -- deriving (Eq, Show)

instance InputSource KafkaSource where
  partitionProducer (KafkaSource _ _ _) _ _ = undefined
{-
  partitionProducer (KafkaSource kOpts) partitionStr offset = do
    let partition = read partitionStr :: Int
    (_, kTopic) <- lift $ forceEitherIO UnexpectedKafkaError $ kafkaFromOptions kOpts KafkaConsumer
    lift $ startConsuming kTopic partition $ KafkaOffset (fromIntegral offset)
    kConsumer kTopic partition

    where
      kConsumer kTopic partition = forever $ do
        me <- lift $ consumeMessage kTopic partition (defaultKafkaTimeout kOpts)
        case me of 
          (Left (KafkaResponseError RdKafkaRespErrPartitionEof)) ->
            lift $ infoM $ "End of partition " ++ show partition ++ ": waiting for producer"
          Left e -> 
            lift $ errorM $ "Got error while consuming from Kafka: " ++ show e
          Right m -> do
            yield $ InputTuple (messagePayload m) 
                               (show $ messagePartition m) 
                               (fromIntegral $ messageOffset m)
-}
  allPartitions (KafkaSource kOpts kafka kTopic) = do --return ["0"]
    md <- forceEitherIO UnexpectedKafkaError $ getTopicMetadata kafka kTopic (defaultKafkaTimeout kOpts)
    forM (topicPartitions md) $ \et -> case et of
        Left _ -> throw UnexpectedKafkaError
        Right tmd -> return $ show $ partitionId tmd
{-
  allPartitions (KafkaSource kOpts) = do
    kConf <- newKafkaConf
    kTopicConf <- newKafkaTopicConf
    (kafka, kTopic) <- forceEitherIO UnexpectedKafkaError $ kafkaProducerFromOptions kOpts
    md <- forceEitherIO UnexpectedKafkaError $ getTopicMetadata kafka kTopic (defaultKafkaTimeout kOpts)
    forM (topicPartitions md) $ \et -> case et of
        Left _ -> throw UnexpectedKafkaError
        Right tmd -> return $ show $ partitionId tmd
-}
  startClock s = allPartitions s >>= \ps ->
    return $ Clock $ Map.fromList $ zip ps (repeat (- 2))
