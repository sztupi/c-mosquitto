{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Mosquitto
  ( module Network.Mosquitto )
where

import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Trans.Control
import           Data.Char (chr)
import           Data.Coerce (coerce)
import           Data.Monoid ((<>))
import           Foreign.C.String (peekCString, peekCStringLen)
import           Foreign.C.Types
import           Foreign.ForeignPtr (ForeignPtr, withForeignPtr, newForeignPtr_)
import           Foreign.Marshal.Alloc ( alloca )
import           Foreign.Ptr ( Ptr, nullPtr, castPtr, FunPtr)

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU

import           Language.C.Inline.TypeLevel

import           System.IO.Unsafe (unsafePerformIO)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BS

import           Network.Mosquitto.Internal.Types
import           Network.Mosquitto.Internal.Inline
import           Foreign.Storable

import           Network.Mosquitto.Internal.Types as Network.Mosquitto (Mosquitto, Message(..))

C.context (C.baseCtx <> C.vecCtx <> C.funCtx <> mosquittoCtx)
C.include "<stdio.h>"
C.include "<mosquitto.h>"

c'MessageToMMessage :: Ptr C'Message -> IO Message
c'MessageToMMessage ptr =
   Message
    <$> (fromIntegral <$> [C.exp| int { $(struct mosquitto_message * ptr)->mid}  |])
    <*> (peekCString =<< [C.exp| char * {$(struct mosquitto_message * ptr) -> topic } |])
    <*> (C8.packCStringLen =<< (,)
             <$> [C.exp| char * {$(struct mosquitto_message * ptr) -> payload } |]
             <*> fmap fromIntegral [C.exp| int {$(struct mosquitto_message * ptr) -> payloadlen } |])
    <*> (fromIntegral <$> [C.exp| int { $(struct mosquitto_message * ptr)->qos}  |])
    <*> [C.exp| bool { $(struct mosquitto_message * ptr)->retain}  |]

{-# NOINLINE init #-}
init = [C.exp| int{ mosquitto_lib_init() }|]

{-# NOINLINE cleanup #-}
cleanup = [C.exp| int{ mosquitto_lib_cleanup() }|]

withMosquittoLibrary :: MonadBase IO m => m a -> m a
withMosquittoLibrary f = (liftBase Network.Mosquitto.init) *> f <* (liftBase cleanup)

{-# NOINLINE version #-}
version :: (Int, Int, Int)
version = unsafePerformIO $
  alloca $ \a -> alloca $ \b -> alloca $ \c -> do
      [C.block|void{ mosquitto_lib_version($(int *a),$(int *b),$(int *c)); }|]
      (,,) <$> peek' a
           <*> peek' b
           <*> peek' c
 where
   peek' x = fromIntegral <$> peek x

newMosquitto
  :: MonadBase IO m
  => Bool -> String -> Maybe a -> m (Mosquitto a)
newMosquitto clearSession (nullTermStr -> userId) _userData = liftBase $ do
   fp <- newForeignPtr_ <$> [C.block|struct mosquitto *{
        struct mosquitto * p =
          mosquitto_new( $bs-ptr:userId
                       , $(bool clearSession)
                       , 0 // (void * ptrUserData)
                       );
        mosquitto_threaded_set(p, true);
        return p;
      }|]

   Mosquitto <$> fp

destroyMosquitto
  :: MonadBase IO m
  => Mosquitto a
  -> m ()
destroyMosquitto ms = liftBase $ withPtr ms $ \ptr ->
   [C.exp|void{
         mosquitto_destroy($(struct mosquitto *ptr))
     }|]

setTls
  :: MonadBase IO m
  => Mosquitto a -> String -> Maybe (String, String) -> m ()
setTls mosq (nullTermStr -> caFile) userCert = liftBase $
  withPtr mosq $ \pMosq -> do
    (certFile, keyFile) <- case userCert of
      Just (nullTermStr -> certFile, nullTermStr -> keyFile) ->
        (,) <$> [C.exp| char* {$bs-ptr:certFile} |]
            <*> [C.exp| char* {$bs-ptr:keyFile}  |]
      Nothing ->
        return (nullPtr, nullPtr)
    [C.exp|void{
            mosquitto_tls_set( $(struct mosquitto *pMosq)
                            , $bs-ptr:caFile
                            , 0
                            , $(char* certFile)
                            , $(char* keyFile)
                            , 0
                            )
    }|]

setReconnectDelay
  :: MonadBase IO m
  => Mosquitto a -- ^ mosquitto instance
  -> Bool        -- ^ exponential backoff
  -> Int         -- ^ initial backoff
  -> Int         -- ^ maximum backoff
  -> m Int
setReconnectDelay mosq  exponential (fromIntegral -> reconnectDelay) (fromIntegral -> reconnectDelayMax) = liftBase $ 
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_reconnect_delay_set
               ( $(struct mosquitto *pMosq)
               , $(int reconnectDelay)
               , $(int reconnectDelayMax)
               , $(bool exponential)
               )
        }|]

setUsernamePassword
  :: MonadBase IO m
  => Mosquitto a
  -> Maybe (String,String)
  -> m Int
setUsernamePassword mosq mUserPwd = liftBase $
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
    case mUserPwd of
      Just (nullTermStr -> user, nullTermStr -> pwd) ->
        [C.exp|int{
                mosquitto_username_pw_set
                  ( $(struct mosquitto *pMosq)
                  , $bs-ptr:user
                  , $bs-ptr:pwd
                  )
        }|]
      Nothing ->
        [C.exp|int{
                mosquitto_username_pw_set
                  ( $(struct mosquitto *pMosq)
                  , NULL
                  , NULL
                  )
        }|]

connect
  :: MonadBase IO m
  => Mosquitto a -> String -> Int -> Int -> m Int
connect mosq (nullTermStr -> hostname) (fromIntegral -> port) (fromIntegral -> keepAlive) = liftBase $
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
               mosquitto_connect( $(struct mosquitto *pMosq)
                                , $bs-ptr:hostname
                                , $(int port)
                                , $(int keepAlive)
                                )
             }|]

onSubscribe
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnSubscribe m -> m ()
onSubscribe mosq onSubscribeF =
  liftBaseWith $ \runInBase -> do
    on_subscribe <- mkCOnSubscribe $ \_ _ mid (fromIntegral -> ii) iis -> do
      args <- mapM (fmap fromIntegral . peekElemOff iis) [0..ii-1]
      runInBase $ onSubscribeF (fromIntegral mid) args
    withPtr mosq $ \pMosq ->
      [C.block|void{
          mosquitto_subscribe_callback_set
              ( $(struct mosquitto *pMosq)
              , $(void (*on_subscribe)(struct mosquitto *,void *, int, int, const int *))
              );
        }|]


onConnect
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnConnection m -> m ()
onConnect mosq onConnect =
  liftBaseWith $ \runInBase -> do
    on_connect <- mkCOnConnection $ \_ _ ii -> runInBase $ onConnect (fromIntegral ii)
    withPtr mosq $ \pMosq ->
      [C.block|void{
          mosquitto_connect_callback_set
              ( $(struct mosquitto *pMosq)
              , $(void (*on_connect)(struct mosquitto *,void *, int))
              );
        }|]

onDisconnect
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnConnection m -> m ()
onDisconnect mosq onDisconnect =
  liftBaseWith $ \runInBase -> do
    on_disconnect <- mkCOnConnection $ \_ _ ii -> runInBase $ onDisconnect (fromIntegral ii)
    withPtr mosq $ \pMosq ->
      [C.block|void{
          mosquitto_disconnect_callback_set
              ( $(struct mosquitto *pMosq)
              , $(void (*on_disconnect)(struct mosquitto *,void *, int))
              );
        }|]

onLog
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnLog m -> m ()
onLog mosq onLog =
  liftBaseWith $ \runInBase -> do
    on_log <- mkCOnLog $ \_ _ ii mm -> runInBase (onLog (fromIntegral ii) =<< liftBase (peekCString mm))
    withPtr mosq $ \pMosq ->
      [C.block|void{
          mosquitto_log_callback_set
              ( $(struct mosquitto *pMosq)
              , $(void (*on_log)(struct mosquitto *,void *, int, const char *))
              );
        }|]

onMessage
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnMessage m -> m ()
onMessage mosq onMessage =
  liftBaseWith $ \runInBase -> do
    on_message <- mkCOnMessage $ \_ _ mm -> runInBase (onMessage =<< liftBase (c'MessageToMMessage mm))
    withPtr mosq $ \pMosq ->
     [C.block|void{
        mosquitto_message_callback_set
            ( $(struct mosquitto *pMosq)
            , $(void (*on_message)(struct mosquitto *, void *, const struct mosquitto_message *))
            );
       }|]

onPublish
  :: ( MonadBaseControl IO m
     , StM m () ~ () )
  => Mosquitto a -> OnPublish m -> m ()
onPublish mosq onPublish =
  liftBaseWith $ \runInBase -> do
    on_publish <- mkCOnPublish $ \_ _ mid -> runInBase $ onPublish (fromIntegral mid)
    withPtr mosq $ \pMosq ->
      [C.block|void{
          mosquitto_publish_callback_set
              ( $(struct mosquitto *pMosq)
              , $(void (*on_publish)(struct mosquitto *,void *, int))
              );
        }|]

loop :: MonadBase IO m => Mosquitto a -> m ()
loop mosq = liftBase $
  withPtr mosq $ \pMosq ->
    [C.exp|void{
             mosquitto_loop($(struct mosquitto *pMosq), -1, 1)
        }|]

loopForever :: MonadBase IO m => Mosquitto a -> m ()
loopForever mosq = liftBase $
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_loop_forever($(struct mosquitto *pMosq), -1, 1)
        }|]

setTlsInsecure :: MonadBase IO m => Mosquitto a -> Bool -> m ()
setTlsInsecure mosq isInsecure = liftBase $
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_tls_insecure_set($(struct mosquitto *pMosq), $(bool isInsecure))
        }|]

setWill :: MonadBase IO m => Mosquitto a -> Bool -> Int -> String -> S.ByteString -> m Int
setWill mosq retain (fromIntegral -> qos) (nullTermStr -> topic) payload = liftBase $
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
       [C.exp|int{
             mosquitto_will_set
               ( $(struct mosquitto *pMosq)
               , $bs-ptr:topic
               , $bs-len:payload
               , $bs-ptr:payload
               , $(int qos)
               , $(bool retain)
               )
        }|]

clearWill :: MonadBase IO m => Mosquitto a -> m Int
clearWill mosq = liftBase $
  fmap fromIntegral <$> withPtr mosq $ \pMosq ->
        [C.exp|int{
             mosquitto_will_clear($(struct mosquitto *pMosq))
        }|]

publish :: MonadBase IO m => Mosquitto a -> Bool -> Int -> String -> S.ByteString -> m ()
publish mosq retain (fromIntegral -> qos) (nullTermStr -> topic) payload = liftBase $
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_publish
               ( $(struct mosquitto *pMosq)
               , 0
               , $bs-ptr:topic
               , $bs-len:payload
               , $bs-ptr:payload
               , $(int qos)
               , $(bool retain)
               )
        }|]

subscribe :: MonadBase IO m => Mosquitto a -> Int -> String -> m ()
subscribe mosq (fromIntegral -> qos) (nullTermStr -> topic) = liftBase $
  withPtr mosq $ \pMosq ->
       [C.exp|void{
             mosquitto_subscribe
               ( $(struct mosquitto *pMosq)
               , 0
               , $bs-ptr:topic
               , $(int qos)
               )
        }|]

strerror :: MonadBase IO m => Int -> m String
strerror (fromIntegral -> errno) = liftBase $ do
  cstr <- [C.exp|const char*{
              mosquitto_strerror( $(int errno)  )
            }|]
  peekCString cstr

nullTermStr :: String -> S.ByteString
nullTermStr = (<> C8.singleton (chr 0)) . C8.pack
