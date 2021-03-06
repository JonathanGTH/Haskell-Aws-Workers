{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Lib
    ( go
    ) where

import qualified Aws
import qualified Aws.Core
import qualified Aws.S3                     as S3
import qualified Aws.Sqs                    as Sqs
import           Aws.Sqs.Core               hiding (sqs)
import           Control.Concurrent
import           Control.Error
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Data.Monoid
import qualified Data.Text                  as T
import qualified Data.Text.IO               as T
import qualified Data.Text.Read             as TR
import           Network.HTTP.Conduit
import           Types

sqsEndpointUsEast :: Endpoint
sqsEndpointUsEast
    = Endpoint {
        endpointHost = "sqs.us-east-2.amazonaws.com"
      , endpointDefaultLocationConstraint = "us-east-2"
      , endpointAllowedLocationConstraints = ["us-east-2"]
      }

pull :: MonadIO io
     => Int
     -> QueueM io [Sqs.Message]
pull n = do
  ctx <- ask
  let req = Sqs.ReceiveMessage
                Nothing
                []
                (Just n)
                []
                (queueName ctx)
                (Just 20)
  Sqs.ReceiveMessageResponse msgs <-
    Aws.simpleAws (aws ctx) (sqs ctx) req
  return (case msgs of
    [] -> Left QueueEmpty
    _ -> Right msgs)

delete :: MonadIO io
       => Sqs.Message
       -> QueueM io Sqs.DeleteMessageResponse
delete Sqs.Message{..} = do
  ctx <- ask
  let req = Sqs.DeleteMessage mReceiptHandle (queueName ctx)
  res <- Aws.simpleAws (aws ctx) (sqs ctx) req
  return (Right res)

push :: MonadIO io
     => T.Text
     -> QueueM io Sqs.SendMessageResponse
push message = do
  ctx <- ask
  let req = Sqs.SendMessage message (queueName ctx) [] Nothing
  res <- Aws.simpleAws (aws ctx) (sqs ctx) req
  return (Right res)

doWork :: ReaderT SQSContext IO ()
doWork = do
  ctx <- ask
  eitherMessages <- pull 10

  case eitherMessages of
    Left err -> liftIO $
      case err of
        QueueEmpty -> do
          putStrLn "Waiting for more work..."
          threadDelay 10000000

        _ ->
          putStrLn ("Error: " <> show err)

    Right messages ->
      forM_ messages $ \message -> do
        status <- liftIO (work message)
        case status of
          WorkSuccess -> do
            delete message
            let newMessage msg
                  | T.length msg < 100 = "new" <> msg
                  | otherwise = "reset"
            push (newMessage (Sqs.mBody message))
            return ()
          WorkError err -> liftIO (T.putStrLn ("Error: " <> err))

  doWork

work :: Sqs.Message -> IO WorkStatus
work Sqs.Message{..} =
  if T.take 4 mBody == "fail"
    then return (WorkError ("Fail! Message Body: " <> mBody))
    else T.putStrLn mBody >> return WorkSuccess

go :: T.Text -> T.Text -> IO ()
go queue amazonId = do
  cfg <- Aws.baseConfiguration

  let sqscfg = Sqs.sqs Aws.Core.HTTP sqsEndpointUsEast False :: Sqs.SqsConfiguration Aws.NormalQuery
  let sqsQueueName = Sqs.QueueName queue amazonId
  let ctx = SQSContext cfg sqscfg sqsQueueName

  runReaderT doWork ctx
