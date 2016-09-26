{-# LANGUAGE CPP                    #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}
#if __GLASGOW_HASKELL__ >= 800
{-# OPTIONS_GHC -freduction-depth=100 #-}
#else
{-# OPTIONS_GHC -fcontext-stack=100 #-}
#endif
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Servant.ClientSpec where

import           Prelude ()
import           Prelude.Compat

import           Control.Arrow              (left)
import           Control.Monad.Trans.Except (throwE )
import           Data.Aeson
import qualified Data.ByteString.Lazy       as BS
import           Data.Char                  (chr, isPrint)
import           Data.Foldable              (forM_)
import           Data.Monoid                hiding (getLast)
import           Data.Proxy
import           GHC.Generics               (Generic)
import qualified Network.HTTP.Client        as C
import           Network.HTTP.Media
import qualified Network.HTTP.Types as HTTP
import           Network.Wai                (responseLBS)
import qualified Network.Wai as Wai
import           System.Exit.Compat
import           System.IO.Unsafe           (unsafePerformIO)
import           Test.HUnit
import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck
import           Web.FormUrlEncoded         (FromForm, ToForm)

import           Servant.API
import           Servant.Client
import           Servant.Client.TestServer
import           Servant.Client.TestServer.GHC
import qualified Servant.Common.Req as SCR
import           Servant.Server
import           Servant.Server.Experimental.Auth

spec :: Spec
spec = do
  runIO buildTestServer
  describe "Servant.Client" $ do
    sucessSpec
    failSpec
    basicAuthSpec
    genAuthSpec
    errorSpec

-- | Run a test-server (identified by name) while performing the given action.
-- The provided 'BaseUrl' points to the running server.
--
-- Running the test-servers is done differently depending on the compiler
-- (ghc or ghcjs).
--
-- With ghc it's somewhat straight-forward: a wai 'Application' is being started
-- on a free port inside the same process using 'warp'.
--
-- When running the test-suite with ghcjs all the test-servers are compiled into
-- a single external executable (with ghc and warp). This is done through
-- 'buildTestServer' once at the start of the test-suite. This built executable
-- will provide all the test-servers on a free port under a path that
-- corresponds to the test-servers name, for example under
-- 'http://localhost:82923/failServer'. 'withTestServer' will then
-- start this executable as an external process while the given action is being
-- executed and provide it with the correct BaseUrl.
-- This rather cumbersome approach is taken because it's not easy to run a wai
-- Application as a http server when using ghcjs.
withTestServer :: String -> (BaseUrl -> IO a) -> IO a
withTestServer name action = do
  server <- lookupTestServer name
  withServer server action

lookupTestServer :: String -> IO TestServer
lookupTestServer name = case lookup name mapping of
  Nothing -> die ("test server not found: " ++ name)
  Just testServer -> return testServer
  where
    mapping :: [(String, TestServer)]
    mapping = map (\ server -> (testServerName server, server)) allTestServers

-- | All test-servers must be registered here.
allTestServers :: [TestServer]
allTestServers =
  server :
  errorServer :
  failServer :
  basicAuthServer :
  genAuthServer :
  []

-- * test data types

data Person = Person {
  name :: String,
  age :: Integer
 }
  deriving (Eq, Show, Generic)

instance ToJSON Person
instance FromJSON Person

instance ToForm Person where
instance FromForm Person where

alice :: Person
alice = Person "Alice" 42

type TestHeaders = '[Header "X-Example1" Int, Header "X-Example2" String]

type Api =
       "get" :> Get '[JSON] Person
  :<|> "deleteEmpty" :> DeleteNoContent '[JSON] NoContent
  :<|> "capture" :> Capture "name" String :> Get '[JSON,FormUrlEncoded] Person
  :<|> "captureAll" :> CaptureAll "names" String :> Get '[JSON] [Person]
  :<|> "body" :> ReqBody '[FormUrlEncoded,JSON] Person :> Post '[JSON] Person
  :<|> "param" :> QueryParam "name" String :> Get '[FormUrlEncoded,JSON] Person
  :<|> "params" :> QueryParams "names" String :> Get '[JSON] [Person]
  :<|> "flag" :> QueryFlag "flag" :> Get '[JSON] Bool
  :<|> "rawSuccess" :> Raw
  :<|> "rawFailure" :> Raw
  :<|> "multiple" :>
            Capture "first" String :>
            QueryParam "second" Int :>
            QueryFlag "third" :>
            ReqBody '[JSON] [(String, [Rational])] :>
            Get '[JSON] (String, Maybe Int, Bool, [(String, [Rational])])
  :<|> "headers" :> Get '[JSON] (Headers TestHeaders Bool)
  :<|> "deleteContentType" :> DeleteNoContent '[JSON] NoContent
api :: Proxy Api
api = Proxy

getGet          :: SCR.ClientM Person
getDeleteEmpty  :: SCR.ClientM NoContent
getCapture      :: String -> SCR.ClientM Person
getCaptureAll   :: [String] -> SCR.ClientM [Person]
getBody         :: Person -> SCR.ClientM Person
getQueryParam   :: Maybe String -> SCR.ClientM Person
getQueryParams  :: [String] -> SCR.ClientM [Person]
getQueryFlag    :: Bool -> SCR.ClientM Bool
getRawSuccess :: HTTP.Method
  -> SCR.ClientM (Int, BS.ByteString, MediaType, [HTTP.Header], C.Response BS.ByteString)
getRawFailure   :: HTTP.Method
  -> SCR.ClientM (Int, BS.ByteString, MediaType, [HTTP.Header], C.Response BS.ByteString)
getMultiple     :: String -> Maybe Int -> Bool -> [(String, [Rational])]
  -> SCR.ClientM (String, Maybe Int, Bool, [(String, [Rational])])
getRespHeaders  :: SCR.ClientM (Headers TestHeaders Bool)
getDeleteContentType :: SCR.ClientM NoContent
getGet
  :<|> getDeleteEmpty
  :<|> getCapture
  :<|> getCaptureAll
  :<|> getBody
  :<|> getQueryParam
  :<|> getQueryParams
  :<|> getQueryFlag
  :<|> getRawSuccess
  :<|> getRawFailure
  :<|> getMultiple
  :<|> getRespHeaders
  :<|> getDeleteContentType = client api

server :: TestServer
server = TestServer "server" $ serve api (
       return alice
  :<|> return NoContent
  :<|> (\ name -> return $ Person name 0)
  :<|> (\ names -> return (zipWith Person names [0..]))
  :<|> return
  :<|> (\ name -> case name of
                   Just "alice" -> return alice
                   Just n -> throwE $ ServantErr 400 (n ++ " not found") "" []
                   Nothing -> throwE $ ServantErr 400 "missing parameter" "" [])
  :<|> (\ names -> return (zipWith Person names [0..]))
  :<|> return
  :<|> (\ _request respond -> respond $ responseLBS HTTP.ok200 [] "rawSuccess")
  :<|> (\ _request respond -> respond $ responseLBS HTTP.badRequest400 [] "rawFailure")
  :<|> (\ a b c d -> return (a, b, c, d))
  :<|> (return $ addHeader 1729 $ addHeader "eg2" True)
  :<|> return NoContent
 )

type FailApi =
       "get" :> Raw
  :<|> "capture" :> Capture "name" String :> Raw
  :<|> "body" :> Raw

failApi :: Proxy FailApi
failApi = Proxy

failServer :: TestServer
failServer = TestServer "failServer" $ serve failApi (
       (\ _request respond -> respond $ responseLBS HTTP.ok200 [] "")
  :<|> (\ _capture _request respond -> respond $ responseLBS HTTP.ok200 [("content-type", "application/json")] "")
  :<|> (\ _request respond -> respond $ responseLBS HTTP.ok200 [("content-type", "fooooo")] "")
 )

-- * basic auth stuff

type BasicAuthAPI =
       BasicAuth "foo-realm" () :> "private" :> "basic" :> Get '[JSON] Person

basicAuthAPI :: Proxy BasicAuthAPI
basicAuthAPI = Proxy

basicAuthHandler :: BasicAuthCheck ()
basicAuthHandler =
  let check (BasicAuthData username password) =
        if username == "servant" && password == "server"
        then return (Authorized ())
        else return Unauthorized
  in BasicAuthCheck check

basicServerContext :: Context '[ BasicAuthCheck () ]
basicServerContext = basicAuthHandler :. EmptyContext

basicAuthServer :: TestServer
basicAuthServer = TestServer "basicAuthServer" $
  serveWithContext basicAuthAPI basicServerContext (const (return alice))

-- * general auth stuff

type GenAuthAPI =
  AuthProtect "auth-tag" :> "private" :> "auth" :> Get '[JSON] Person

genAuthAPI :: Proxy GenAuthAPI
genAuthAPI = Proxy

type instance AuthServerData (AuthProtect "auth-tag") = ()
type instance AuthClientData (AuthProtect "auth-tag") = ()

genAuthHandler :: AuthHandler Wai.Request ()
genAuthHandler =
  let handler req = case lookup "AuthHeader" (Wai.requestHeaders req) of
        Nothing -> throwE (err401 { errBody = "Missing auth header" })
        Just _ -> return ()
  in mkAuthHandler handler

genAuthServerContext :: Context '[ AuthHandler Wai.Request () ]
genAuthServerContext = genAuthHandler :. EmptyContext

genAuthServer :: TestServer
genAuthServer = TestServer "genAuthServer" $
  serveWithContext genAuthAPI genAuthServerContext (const (return alice))

{-# NOINLINE manager #-}
manager :: C.Manager
manager = unsafePerformIO $ C.newManager C.defaultManagerSettings

sucessSpec :: Spec
sucessSpec = around (withTestServer "server") $ do

    it "Servant.API.Get" $ \baseUrl -> do
      (left show <$> (runClientM getGet  (ClientEnv manager baseUrl)))  `shouldReturn` Right alice

    describe "Servant.API.Delete" $ do
      it "allows empty content type" $ \baseUrl -> do
        (left show <$> (runClientM getDeleteEmpty (ClientEnv manager baseUrl))) `shouldReturn` Right NoContent

      it "allows content type" $ \baseUrl -> do
        (left show <$> (runClientM getDeleteContentType (ClientEnv manager baseUrl))) `shouldReturn` Right NoContent

    it "Servant.API.Capture" $ \baseUrl -> do
      (left show <$> (runClientM (getCapture "Paula") (ClientEnv manager baseUrl))) `shouldReturn` Right (Person "Paula" 0)

    it "Servant.API.CaptureAll" $ \baseUrl -> do
      let expected = [(Person "Paula" 0), (Person "Peta" 1)]
      (left show <$> (runClientM (getCaptureAll ["Paula", "Peta"]) (ClientEnv  manager baseUrl))) `shouldReturn` Right expected

    it "Servant.API.ReqBody" $ \baseUrl -> do
      let p = Person "Clara" 42
      (left show <$> runClientM (getBody p) (ClientEnv manager baseUrl)) `shouldReturn` Right p

    it "Servant.API.QueryParam" $ \baseUrl -> do
      left show <$> runClientM (getQueryParam (Just "alice")) (ClientEnv manager baseUrl)  `shouldReturn` Right alice
      Left FailureResponse{..} <- runClientM (getQueryParam (Just "bob")) (ClientEnv manager baseUrl)
      responseStatus `shouldBe` HTTP.Status 400 "bob not found"

    it "Servant.API.QueryParam.QueryParams" $ \baseUrl -> do
      (left show <$> runClientM (getQueryParams []) (ClientEnv manager baseUrl)) `shouldReturn` Right []
      (left show <$> runClientM (getQueryParams ["alice", "bob"]) (ClientEnv manager baseUrl))
        `shouldReturn` Right [Person "alice" 0, Person "bob" 1]

    context "Servant.API.QueryParam.QueryFlag" $
      forM_ [False, True] $ \ flag -> it (show flag) $ \baseUrl -> do
        (left show <$> runClientM (getQueryFlag flag) (ClientEnv manager baseUrl)) `shouldReturn` Right flag

    it "Servant.API.Raw on success" $ \baseUrl -> do
      res <- runClientM (getRawSuccess HTTP.methodGet) (ClientEnv manager baseUrl)
      case res of
        Left e -> assertFailure $ show e
        Right (code, body, ct, _, response) -> do
          (code, body, ct) `shouldBe` (200, "rawSuccess", "application"//"octet-stream")
          C.responseBody response `shouldBe` body
          C.responseStatus response `shouldBe` HTTP.ok200

    it "Servant.API.Raw should return a Left in case of failure" $ \baseUrl -> do
      res <- runClientM (getRawFailure HTTP.methodGet) (ClientEnv manager baseUrl)
      case res of
        Right _ -> assertFailure "expected Left, but got Right"
        Left e -> do
          Servant.Client.responseStatus e `shouldBe` HTTP.status400
          Servant.Client.responseBody e `shouldBe` "rawFailure"

    it "Returns headers appropriately" $ \baseUrl -> do
      res <- runClientM getRespHeaders (ClientEnv manager baseUrl)
      case res of
        Left e -> assertFailure $ show e
        Right val -> getHeaders val `shouldBe` [("X-Example1", "1729"), ("X-Example2", "eg2")]

    modifyMaxSuccess (const 20) $ do
      it "works for a combination of Capture, QueryParam, QueryFlag and ReqBody" $ \baseUrl ->
        property $ forAllShrink pathGen shrink $ \(NonEmpty cap) num flag body ->
          ioProperty $ do
            result <- left show <$> runClientM (getMultiple cap num flag body) (ClientEnv manager baseUrl)
            return $
              result === Right (cap, num, flag, body)

type ErrorApi =
  Delete '[JSON] () :<|>
  Get '[JSON] () :<|>
  Post '[JSON] () :<|>
  Put '[JSON] ()

errorApi :: Proxy ErrorApi
errorApi = Proxy

errorServer :: TestServer
errorServer = TestServer "errorServer" $ serve errorApi $
  err :<|> err :<|> err :<|> err
  where
    err = throwE $ ServantErr 500 "error message" "" []

errorSpec :: Spec
errorSpec =
  around (withTestServer "errorServer") $ do
    describe "error status codes" $
      it "reports error statuses correctly" $ \baseUrl -> do
        let delete :<|> get :<|> post :<|> put =
              client errorApi
            actions = [delete, get, post, put]
        forM_ actions $ \ clientAction -> do
          Left FailureResponse{..} <- runClientM clientAction (ClientEnv manager baseUrl)
          responseStatus `shouldBe` HTTP.Status 500 "error message"

basicAuthSpec :: Spec
basicAuthSpec = around (withTestServer "basicAuthServer") $ do
  context "Authentication works when requests are properly authenticated" $ do

    it "Authenticates a BasicAuth protected server appropriately" $ \baseUrl -> do
      let getBasic = client basicAuthAPI
      let basicAuthData = BasicAuthData "servant" "server"
      (left show <$> runClientM (getBasic basicAuthData) (ClientEnv manager baseUrl)) `shouldReturn` Right alice

  context "Authentication is rejected when requests are not authenticated properly" $ do

    it "Authenticates a BasicAuth protected server appropriately" $ \baseUrl -> do
      let getBasic = client basicAuthAPI
      let basicAuthData = BasicAuthData "not" "password"
      Left FailureResponse{..} <- runClientM (getBasic basicAuthData) (ClientEnv manager baseUrl)
      responseStatus `shouldBe` HTTP.Status 403 "Forbidden"

genAuthSpec :: Spec
genAuthSpec = around (withTestServer "genAuthServer") $ do
  context "Authentication works when requests are properly authenticated" $ do

    it "Authenticates a AuthProtect protected server appropriately" $ \baseUrl -> do
      let getProtected = client genAuthAPI
      let authRequest = mkAuthenticateReq () (\_ req ->  SCR.addHeader "AuthHeader" ("cool" :: String) req)
      (left show <$> runClientM (getProtected authRequest) (ClientEnv manager baseUrl)) `shouldReturn` Right alice

  context "Authentication is rejected when requests are not authenticated properly" $ do

    it "Authenticates a AuthProtect protected server appropriately" $ \baseUrl -> do
      let getProtected = client genAuthAPI
      let authRequest = mkAuthenticateReq () (\_ req ->  SCR.addHeader "Wrong" ("header" :: String) req)
      Left FailureResponse{..} <- runClientM (getProtected authRequest) (ClientEnv manager baseUrl)
      responseStatus `shouldBe` (HTTP.Status 401 "Unauthorized")

failSpec :: Spec
failSpec = around (withTestServer "failServer") $ do

    context "client returns errors appropriately" $ do
      it "reports FailureResponse" $ \baseUrl -> do
        let (_ :<|> getDeleteEmpty :<|> _) = client api
        Left res <- runClientM getDeleteEmpty (ClientEnv manager baseUrl)
        case res of
          FailureResponse (HTTP.Status 404 "Not Found") _ _ -> return ()
          _ -> fail $ "expected 404 response, but got " <> show res

      it "reports DecodeFailure" $ \baseUrl -> do
        let (_ :<|> _ :<|> getCapture :<|> _) = client api
        Left res <- runClientM (getCapture "foo") (ClientEnv manager baseUrl)
        case res of
          DecodeFailure _ ("application/json") _ -> return ()
          _ -> fail $ "expected DecodeFailure, but got " <> show res

      it "reports ConnectionError" $ \_ -> do
        let (getGetWrongHost :<|> _) = client api
        Left res <- runClientM getGetWrongHost (ClientEnv manager (BaseUrl Http "127.0.0.1" 19872 ""))
        case res of
          ConnectionError _ -> return ()
          _ -> fail $ "expected ConnectionError, but got " <> show res

      it "reports UnsupportedContentType" $ \baseUrl -> do
        let (getGet :<|> _ ) = client api
        Left res <- runClientM getGet (ClientEnv manager baseUrl)
        case res of
          UnsupportedContentType ("application/octet-stream") _ -> return ()
          _ -> fail $ "expected UnsupportedContentType, but got " <> show res

      it "reports InvalidContentTypeHeader" $ \baseUrl -> do
        let (_ :<|> _ :<|> _ :<|> _ :<|> getBody :<|> _) = client api
        Left res <- runClientM (getBody alice) (ClientEnv manager baseUrl)

        case res of
          InvalidContentTypeHeader "fooooo" _ -> return ()
          _ -> fail $ "expected InvalidContentTypeHeader, but got " <> show res

-- * utils

pathGen :: Gen (NonEmptyList Char)
pathGen = fmap NonEmpty path
 where
  path = listOf1 $ elements $
    filter (not . (`elem` ("?%[]/#;" :: String))) $
    filter isPrint $
    map chr [0..127]
