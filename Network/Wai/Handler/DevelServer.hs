{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Wai.Handler.DevelServer (run, runNoWatch) where

import Language.Haskell.Interpreter
import Network.Wai

import Data.Text.Lazy (pack)
import Data.Text.Lazy.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy.Char8 as L8
import Network
    ( listenOn, accept, sClose, PortID(PortNumber), Socket
    , withSocketsDo)
import Control.Exception (bracket, finally, Exception,
                          SomeException, toException)
import qualified Control.Exception as E
import System.IO (Handle, hClose)
import Control.Concurrent (forkIO, threadDelay)

import qualified Control.Concurrent.MVar as M
import qualified Control.Concurrent.Chan as C
import System.Directory (getModificationTime)
import Network.Wai.Handler.Warp (parseRequest, sendResponse, drainRequestBody)
import Control.Monad (filterM)

import Control.Arrow ((&&&))
import System.Directory (doesDirectoryExist,
                         doesFileExist, getDirectoryContents)
import Control.Applicative ((<$>))

import Data.List (nub)

type FunctionName = String

runNoWatch :: Port -> ModuleName -> FunctionName -> [FilePath] -> IO ()
runNoWatch port modu func dirs = do
    queue <- C.newChan
    mqueue <- M.newMVar queue
    startApp queue $ loadingApp Nothing
    reload modu func mqueue dirs Nothing
    run' port mqueue

run :: Port -> ModuleName -> FunctionName -> [FilePath] -> IO ()
run port modu func dirs = do
    queue <- C.newChan
    mqueue <- M.newMVar queue
    startApp queue $ loadingApp Nothing
    _ <- forkIO $ fillApp modu func mqueue dirs
    run' port mqueue

startApp :: Queue -> Handler -> IO ()
startApp queue withApp = do
    forkIO (withApp go) >> return ()
  where
    go app = do
        msession <- C.readChan queue
        case msession of
            Nothing -> return ()
            Just (req, onRes) -> do
                void $ forkIO $ (E.handle onErr $ app req) >>= onRes
                go app
    onErr :: SomeException -> IO Response
    onErr e = return
            $ responseLBS
                status500
                [("Content-Type", "text/plain; charset=utf-8")]
            $ charsToLBS
            $ "Exception thrown while running application\n\n" ++ show e
    void x = x >> return ()

getTimes = E.handle (constSE $ return []) . mapM getModificationTime
constSE :: x -> SomeException -> x
constSE = const

fillApp :: String -> String -> M.MVar Queue -> [FilePath] -> IO ()
fillApp modu func mqueue dirs =
    go Nothing []
  where
    go prevError prevFiles = do
        toReload <-
            if null prevFiles
                then return True
                else do
                    times <- getTimes $ map fst prevFiles
                    return $ times /= map snd prevFiles
        (newError, newFiles) <-
            if toReload
                then reload modu func mqueue dirs prevError
                else return (prevError, prevFiles)
        threadDelay 1000000
        go newError newFiles

-- reload :: String -> String -> M.MVar Queue -> [FilePath] -> Maybe SomeException -> IO (Maybe SomeException, [ClockTime])
reload modu func mqueue dirs prevError = do
    case prevError of
         Nothing -> putStrLn "Attempting to interpret your app..."
         _       -> return ()
    loadingApp' prevError mqueue
    res <- theapp modu func
    case res of
        Left err -> do
            if show (Just err) /= show prevError
               then putStrLn $ "Compile failed: " ++ showInterpError err
               else return ()
            loadingApp' (Just $ toException err) mqueue
            return (Just $ toException err, [])
        Right (app, files') -> E.handle onInitErr $ do
            files'' <- mapM fileList dirs
            let files = concat $ files' : files''
            putStrLn "Interpreting success, new app loaded"
            E.handle onInitErr $ do
                swapApp app mqueue
                times <- getTimes files
                return (Nothing, zip files times)
    where
        onInitErr e = do
            putStrLn $ "Error initializing application: " ++ show e
            loadingApp' (Just e) mqueue
            return (Just e, [])

showInterpError :: InterpreterError -> String
showInterpError (WontCompile errs) =
    concat . nub $ map (\(GhcError msg) -> '\n':'\n':msg) errs
showInterpError err = show err

fileList :: FilePath -> IO [FilePath]
fileList top = do
    ex <- doesDirectoryExist top
    if ex then fileList' top "" else return []

fileList' :: FilePath -> FilePath -> IO [FilePath]
fileList' realTop top = do
    let prefix1 = top ++ "/"
        prefix2 = realTop ++ prefix1
    allContents <- filter notHidden <$> getDirectoryContents prefix2
    let all' = map ((++) prefix1 &&& (++) prefix2) allContents
    files <- map snd <$> filterM (doesFileExist . snd) all'
    dirs <- filterM (doesDirectoryExist . snd) all' >>=
            mapM (fileList' realTop . fst)
    return $ concat $ files : dirs

notHidden :: FilePath -> Bool
notHidden ('.':_) = False
notHidden _ = True

loadingApp' :: Maybe SomeException -> M.MVar Queue -> IO ()
loadingApp' err mqueue = swapApp (loadingApp err) mqueue

swapApp :: Handler -> M.MVar Queue -> IO ()
swapApp app mqueue = do
    oldqueue <- M.takeMVar mqueue
    C.writeChan oldqueue Nothing
    queue <- C.newChan
    M.putMVar mqueue queue
    startApp queue app

loadingApp :: Maybe SomeException -> Handler
loadingApp err f =
    f $ const $ return $ responseLBS status200
        ( ("Content-Type", "text/plain")
        : case err of
            Nothing -> [("Refresh", "1")]
            Just _ -> []
        ) $ toMessage err
  where
    toMessage Nothing = "Loading code changes, please wait"
    toMessage (Just err') = charsToLBS $ "Error loading code: " ++ show err'

charsToLBS :: String -> L8.ByteString
charsToLBS = encodeUtf8 . pack

type Handler = (Application -> IO ()) -> IO ()

theapp :: String -> String -> IO (Either InterpreterError (Handler, [FilePath]))
theapp modu func =
    runInterpreter $ do
        loadModules [modu]
        mods <- getLoadedModules
        setImports ["Prelude", "Network.Wai", modu]
        app <- interpret func infer
        return (app, map toFile mods)
  where
    toFile s = map toSlash s ++ ".hs"
    toSlash '.' = '/'
    toSlash c   = c

run' :: Port -> M.MVar Queue -> IO ()
run' port = withSocketsDo .
    bracket
        (listenOn $ PortNumber $ fromIntegral port)
        sClose .
        serveConnections port
type Port = Int

serveConnections :: Port -> M.MVar Queue -> Socket -> IO ()
serveConnections port mqueue socket = do
    (conn, remoteHost', _) <- accept socket
    _ <- forkIO $ serveConnection port mqueue conn remoteHost'
    serveConnections port mqueue socket

type Queue = C.Chan (Maybe (Request, Response -> IO ()))

serveConnection :: Port -> M.MVar Queue -> Handle -> String -> IO ()
serveConnection port mqueue conn remoteHost' = do
    (ilen, env) <- parseRequest port conn remoteHost'
    let onRes res =
            finally
                (do
                    _ <- sendResponse env (httpVersion env) conn res
                    drainRequestBody conn ilen
                    return ())
                (hClose conn)
    queue <- M.readMVar mqueue
    C.writeChan queue $ Just (env, onRes)
