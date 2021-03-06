{-# LANGUAGE QuasiQuotes, TypeFamilies, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module TestApp (testApp) where

import Network.Wai
import Data.ByteString.Lazy.Char8 (pack)
import Database.Persist.Sqlite
import System.Directory
import Control.Monad (when)
import Helper
import Text.Hamlet

mkPersist [$persist|
Dummy
    dummy String
|]

testApp handler = do
    putStrLn "testApp called, this should happen only once per reload"
    -- Swap between the following two lines as necessary to generate errors
    exi <- doesFileExist db
    --let exi = True
    when exi $ removeFile db
    withSqlitePool db 10 $ \pool -> do
        flip runSqlPool pool $ runMigration $ migrate $ Dummy ""
        handler $ \req -> do
            if pathInfo req == "/favicon.ico"
                then return $ Response status301 [("Location", "http://docs.yesodweb.com/favicon.ico")]
                            $ ResponseLBS $ pack ""
                else do
                    print $ pathInfo req
                    x <- flip runSqlPool pool $ do
                        insert $ Dummy ""
                        count ([] :: [Filter Dummy])
                    return $ Response status200
                        [("Content-Type", "text/html; charset=utf-8")]
                        $ ResponseLBS
                        $ renderHamlet id
                        $(hamletFileDebug "hamlet/testapp.hamlet")
        putStrLn "handler completed, this should only happen at the beginning of a reload"
