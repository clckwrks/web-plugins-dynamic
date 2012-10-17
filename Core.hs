{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, MultiParamTypeClasses, RecordWildCards, TemplateHaskell, OverloadedStrings #-}
module Main where

import Control.Applicative
import Control.Exception
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TVar (TVar, newTVar, readTVar, writeTVar, modifyTVar')
import Control.Monad.Trans (MonadIO(liftIO))
import Control.Monad.State (MonadState, StateT, runStateT, get, put, modify)

import Data.Acid
import Data.Acid.Local
import Data.Data
import Data.SafeCopy
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Map  (Map)
import qualified Data.Map as Map
import Data.Monoid
import HSP (XMLGenT, XML)

{-

Insights:

 We have two distinct phases: (ACTUALLY, THIS IS WRONG)

  - initialization that is done before we start listening for requests
  - stuff that happens inside the request handler

If we mix in stuff that is only available when we have a request into
ClckT then we have a hard time using it when there is no active
request (aka, at initialization time).

(AND THIS IS WHY)

Things are actually (probably) more difficult in the precense of hs-plugins. With
hs-plugins we potentially allow plugins to be activated while the
server is already running.

What happens if the use wants to modify parts of the global state
while in a handler? Clearly that requires STM since it is not local to
the request. Alternative, the thread could store the all the actions
that it wants do to (in writer) and they could be performed at the
end.

What are the use cases where we want a thread to be able to modify the
global state? For example, how would one-click plugin installs work?
Perhaps not all plguins can modify the global plugin state?

OBSERVATION: If the global plugin state can be manipulated from more
than one thread, then we must use STM. If the global plugin state can
only happen in one thread, then that means that the request handlers
can not manipulate the plugin state. That seems to conflict with the
goal that we have one-click installs.

-}

{-

When is a plugin in effect?

 1. when a preprocessor gets called

    - this happens in the core clckwrks code so it can't have preknowledge of the plugin

 2. when it is handling a route

 3. when so other plugin calls its methods

 4. on shutdown

 5. by a template the requires a specific plugin

-}

{-

A plugin needs to be able to:

 - generate an internal link
 - generate a link to a parent url
 - generate a page that includes internal links using the parent template function
 - register callbacks that use the plugin context (monad, url-type, etc)
 - access the 'ClckT' context

 - plugins need to initialize and free resources
 - plugin shutdown may care if this is a normal vs error shutdown

Additionally:

 - we only want to do the 'static' calculations once, not everytime we run the route

-}

import Data.Text (Text)

type URLFn url = url -> [(Text, Text)] -> Text

class ShowRoute m url where
    getRouteFn :: m (URLFn url)

data When
    = Always
    | OnFailure
    | OnNormal
      deriving (Eq, Ord, Show)

isWhen :: When -> When -> Bool
isWhen Always _ = True
isWhen x y = x == y

data Cleanup = Cleanup When (IO ())

data PluginsState = PluginsState
    { pluginsPreProcs   :: Map Text (Text -> IO Text)
    , pluginsOnShutdown :: [Cleanup]
    }

newtype Plugins = Plugins { ptv :: TVar PluginsState }

initPlugins :: IO Plugins
initPlugins =
    do ptv <- atomically $ newTVar
              (PluginsState { pluginsPreProcs   = Map.empty
                            , pluginsOnShutdown = []
                            }
              )
       return (Plugins ptv)

destroyPlugins :: When -> Plugins -> IO ()
destroyPlugins whn (Plugins ptv) =
    do pos <- atomically $ pluginsOnShutdown <$> readTVar ptv
       mapM_ (cleanup whn) pos
       return ()
    where
      cleanup whn (Cleanup whn' action)
          | isWhen whn whn' = action
          | otherwise       = return ()

withPlugins :: (Plugins -> IO a) -> IO a
withPlugins action =
    bracketOnError initPlugins
                   (destroyPlugins OnFailure)
                   (\p -> do r <- action p ; destroyPlugins OnNormal p; return r)


addPreProc :: (MonadIO m) => Plugins -> Text -> (Text -> IO Text) -> m ()
addPreProc (Plugins tps) pname pp =
    liftIO $ atomically $ modifyTVar' tps $ \ps@PluginsState{..} ->
              ps { pluginsPreProcs = Map.insert pname pp pluginsPreProcs }


-- | add a new cleanup action to the top of the stack
addCleanup :: (MonadIO m) => Plugins -> When -> IO () -> m ()
addCleanup (Plugins tps) when action =
    liftIO $ atomically $ modifyTVar' tps $ \ps@PluginsState{..} ->
        ps { pluginsOnShutdown = (Cleanup when action) : pluginsOnShutdown }


-- we don't really want to give the Plugin unrestricted access to modify the PluginsState TVar. So we will use a newtype?

data Plugin url st  = Plugin
    { pluginInit       :: Plugins -> IO st
    }

{-

data Plugin url st  = Plugin
    { pluginInit       :: StateT PluginsState IO st
    }

--    , pluginPreProcess ::
--    , pluginRoute    :: url -> [(Text, Text)] -> Text
--    , pluginTemplate :: XMLGenT m XML
--    , pluginRegister :: ClckT ClckURL (ServerPartT IO) (m Response) -- ??


addPreProc :: (MonadState PluginsState m, MonadIO m) => Text -> (Text -> ClckT ClckURL IO Text) -> m ()
addPreProc pname pp =
    modify $ \clckSt@PluginsState{..} ->
        clckSt { clckPreProcs = Map.insert pname pp clckPreProcs }

-- | add a new cleanup action to the top of the stack
addCleanup :: When -> IO () -> StateT PluginsState IO ()
addCleanup when action =
    modify $ \clckSt@PluginsState{..} ->
      clckSt { clckOnShutdown = (Cleanup when action) : clckOnShutdown }

{-

Initializing a plugin generally has side effects. For example, it adds
additional preprocessors to 'PluginsState'. But it can also do things
like open a database, and may need to register finalization actions.

-}
initPlugin :: Plugin url st -> StateT PluginsState IO st
initPlugin Plugin{..} =
    pluginInit
-}
------------------------------------------------------------------------------
-- Example
------------------------------------------------------------------------------

data ClckURL
    = ViewPage
      deriving (Eq, Ord, Show)

data MyState = MyState
    {
    }
    deriving (Eq, Ord, Data, Typeable)
$(deriveSafeCopy 0 'base ''MyState)
$(makeAcidic ''MyState [])


data MyURL
    = MyURL
      deriving (Eq, Ord, Show)


data MyPluginsState = MyPluginsState
    { myAcid :: AcidState MyState
    }

myPreProcessor :: URLFn ClckURL
               -> URLFn MyURL
               -> (Text -> IO Text)
myPreProcessor showFnClckURL showFnMyURL  =
    \t -> return t

{-

Things to do:

 1. open the acid-state for the plugin
 2. register a callback which uses the AcidState
 3. register an action to close the database on shutdown

-}

myInit :: URLFn ClckURL -> URLFn MyURL -> Plugins -> IO MyPluginsState
myInit clckShowFn myShowFn plugins =
    do acid <- liftIO $ openLocalState MyState
       addCleanup plugins OnNormal  (putStrLn "myPlugin: normal shutdown"  >> createCheckpointAndClose acid)
       addCleanup plugins OnFailure (putStrLn "myPlugin: failure shutdown" >> closeAcidState acid)
       addPreProc plugins "my" (myPreProcessor clckShowFn myShowFn)
       putStrLn "myInit completed."
       return (MyPluginsState acid)


myPlugin :: URLFn ClckURL -> URLFn MyURL -> Plugin MyURL MyPluginsState
myPlugin showClckURL showFnMyURL = Plugin
    { pluginInit = myInit showClckURL showFnMyURL
    }


class (Monad m) => MonadRoute m url where
    askRouteFn :: m (url -> [(Text, Text)] -> Text)

mkRouteFn :: (Show url) => Text -> Text -> URLFn url
mkRouteFn baseURI prefix =
    \url params -> baseURI <> "/" <>  prefix <> "/" <> Text.pack (show url)

main :: IO ()
main =
    let baseURI = "http://localhost:8000"
        clckRouteFn = mkRouteFn baseURI "c"
        myRouteFn   = mkRouteFn baseURI "my"
    in
      withPlugins $ \plugins ->
          do mps <- myInit clckRouteFn myRouteFn plugins
             serve plugins ViewPage
             return ()

serve :: Plugins -> ClckURL -> IO ()
serve plugins ViewPage =
    putStrLn "viewing page"


{-
{-

The pre-processor extensions can rely on resources that only exist in the context of the plugin. For example, looking up some information in a local state and generating a link.

But that is a bit interesting, because we can have a bunch of different preprocessers, each with their own context. So, how does that work? Seems most sensible that the preprocessors all have the same, more general type, and internally they can use their `runPluginT` functions to flatten the structure?

When is a plugin in context really even used?

 - pre-processor
 - show a plugin specific page

-}
-}
{-
newtype ClckT url m a = ClckT { unClckT :: URLFn url -> m a }

instance (Functor m) => Functor (ClckT url m) where
    fmap f (ClckT fn) = ClckT $ \u -> fmap f (fn u)

instance (Monad m) => Monad (ClckT url m) where
    return a = ClckT $ const (return a)
    (ClckT m) >>= f =
        ClckT $ \u ->
            do a <- m u
               (unClckT $ f a) u

instance (Monad m) => ShowRoute (ClckT url m) url where
    getRouteFn = ClckT $ \showFn -> return showFn

data ClckURL = ClckURL
-}