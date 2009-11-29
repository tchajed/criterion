-- |
-- Module      : Criterion.Main
-- Copyright   : (c) Bryan O'Sullivan 2009
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Wrappers for compiling and running benchmarks quickly and easily.
-- See 'defaultMain' below for an example.

module Criterion.Main
    (
    -- * How to write benchmarks
    -- $bench

    -- ** Benchmarking IO actions
    -- $io

    -- ** Benchmarking pure code
    -- $pure

    -- ** Fully evaluating a result
    -- $rnf

    -- * Types
      Benchmarkable(..)
    , Benchmark
    , B(..)
    -- * Constructing benchmarks
    , bench
    , bgroup
    -- * Running benchmarks
    , defaultMain
    , defaultMainWith
    -- * Other useful code
    , defaultOptions
    , parseArgs
    ) where

import Control.Monad (MonadPlus(..))
import Control.Monad.Trans (liftIO)
import Criterion (runAndAnalyse)
import Criterion.Config
import Criterion.Environment (measureEnvironment)
import Criterion.IO (note, printError)
import Criterion.MultiMap (singleton)
import Criterion.Monad (withConfig)
import Criterion.Types (Benchmarkable(..), Benchmark(..), B(..), bench,
                        benchNames, bgroup)
import Data.List (isPrefixOf, sort)
import Data.Monoid (Monoid(..), Last(..))
import System.Console.GetOpt
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode(..), exitWith)
import Text.ParserCombinators.Parsec

-- | Parse a plot output.
parsePlot :: Parser PlotOutput
parsePlot = try (dim "window" Window 800 600)
    `mplus` try (dim "win" Window 800 600)
    `mplus` try (dim "pdf" PDF 432 324)
    `mplus` try (dim "png" PNG 800 600)
    `mplus` try (dim "svg" SVG 432 324)
    `mplus` (string "csv" >> return CSV)
  where dim s c dx dy = do
          string s
          try (uncurry c `fmap` dimensions) `mplus`
              (eof >> return (c dx dy))
        dimensions = do
            char ':'
            a <- many1 digit
            char 'x'
            b <- many1 digit
            case (reads a, reads b) of
              ([(x,[])],[(y,[])]) -> return (x, y)
              _                   -> mzero
           <?> "dimensions"

-- | Parse a plot type.
plot :: Plot -> String -> IO Config
plot p s = case parse parsePlot "" s of
             Left _err -> parseError "unknown plot type\n"
             Right t   -> return mempty { cfgPlot = singleton p t }

-- | Parse a confidence interval.
ci :: String -> IO Config
ci s = case reads s' of
         [(d,"%")] -> check (d/100)
         [(d,"")]  -> check d
         _         -> parseError "invalid confidence interval provided"
  where s' = case s of
               ('.':_) -> '0':s
               _       -> s
        check d | d <= 0 = parseError "confidence interval is negative"
                | d >= 1 = parseError "confidence interval is greater than 1"
                | otherwise = return mempty { cfgConfInterval = ljust d }

-- | Parse a positive number.
pos :: (Num a, Ord a, Read a) =>
       String -> (Last a -> Config) -> String -> IO Config
pos q f s =
    case reads s of
      [(n,"")] | n > 0     -> return . f $ ljust n
               | otherwise -> parseError $ q ++ " must be positive"
      _                    -> parseError $ "invalid " ++ q ++ " provided"

noArg :: Config -> ArgDescr (IO Config)
noArg = NoArg . return

-- | The standard options accepted on the command line.
defaultOptions :: [OptDescr (IO Config)]
defaultOptions = [
   Option ['h','?'] ["help"] (noArg mempty { cfgPrintExit = Help })
          "print help, then exit"
 , Option ['G'] ["no-gc"] (noArg mempty { cfgPerformGC = ljust False })
          "do not collect garbage between iterations"
 , Option ['g'] ["gc"] (noArg mempty { cfgPerformGC = ljust True })
          "collect garbage between iterations"
 , Option ['I'] ["ci"] (ReqArg ci "CI")
          "bootstrap confidence interval"
 , Option ['l'] ["list"] (noArg mempty { cfgPrintExit = List })
          "print a list of all benchmark names, then exit"
 , Option ['k'] ["plot-kde"] (ReqArg (plot KernelDensity) "TYPE")
          "plot kernel density estimate of probabilities"
 , Option [] ["kde-same-axis"] (noArg mempty {cfgPlotSameAxis = ljust True })
          "plot all KDE graphs with the same X axis range (useful for comparison)"
 , Option ['q'] ["quiet"] (noArg mempty { cfgVerbosity = ljust Quiet })
          "print less output"
 , Option [] ["resamples"]
          (ReqArg (pos "resample count"$ \n -> mempty { cfgResamples = n }) "N")
          "number of bootstrap resamples to perform"
 , Option ['s'] ["samples"]
          (ReqArg (pos "sample count" $ \n -> mempty { cfgSamples = n }) "N")
          "number of samples to collect"
 , Option ['t'] ["plot-timing"] (ReqArg (plot Timing) "TYPE")
          "plot timings"
 , Option ['u'] ["summary"] (ReqArg (\s -> return $ mempty { cfgSummaryFile = ljust s }) "FILENAME")
          "produce a summary CSV file of all the benchmark means and standard deviations"
 , Option ['V'] ["version"] (noArg mempty { cfgPrintExit = Version })
          "display version, then exit"
 , Option ['v'] ["verbose"] (noArg mempty { cfgVerbosity = ljust Verbose })
          "print more output"
 ]

printBanner :: Config -> IO ()
printBanner cfg = withConfig cfg $ 
    case cfgBanner cfg of
      Last (Just b) -> note "%s\n" b
      _             -> note "Hey, nobody told me what version I am!\n"

printUsage :: [OptDescr (IO Config)] -> ExitCode -> IO a
printUsage options exitCode = do
  p <- getProgName
  putStr (usageInfo ("Usage: " ++ p ++ " [OPTIONS] [BENCHMARKS]") options)
  mapM_ putStrLn [
       ""
    , "If no benchmark names are given, all are run"
    , "Otherwise, benchmarks are run by prefix match"
    , ""
    , "Plot types:"
    , "  window or win   display a window immediately"
    , "  csv             save a CSV file"
    , "  pdf             save a PDF file"
    , "  png             save a PNG file"
    , "  svg             save an SVG file"
    , ""
    , "You can specify plot dimensions via a suffix, e.g. \"window:640x480\""
    , "Units are pixels for png and window, 72dpi points for pdf and svg"
    ]
  exitWith exitCode

-- | Parse command line options.
parseArgs :: Config -> [OptDescr (IO Config)] -> [String]
          -> IO (Config, [String])
parseArgs defCfg options args =
  case getOpt Permute options args of
    (_, _, (err:_)) -> parseError err
    (opts, rest, _) -> do
      cfg <- (mappend defCfg . mconcat) `fmap` sequence opts
      case cfgPrintExit cfg of
        Help ->    printBanner cfg >> printUsage options ExitSuccess
        Version -> printBanner cfg >> exitWith ExitSuccess
        _ ->       return (cfg, rest)

-- | An entry point that can be used as a @main@ function.
--
-- > import Criterion.Main
-- >
-- > fib :: Int -> Int
-- > fib 0 = 0
-- > fib 1 = 1
-- > fib n = fib (n-1) + fib (n-2)
-- >
-- > main = defaultMain [
-- >        bgroup "fib" [ bench "fib 10" $ B fib 10
-- >                     , bench "fib 35" $ B fib 35
-- >                     , bench "fib 37" $ B fib 37
-- >                     ]
-- >                    ]
defaultMain :: [Benchmark] -> IO ()
defaultMain = defaultMainWith defaultConfig

-- | An entry point that can be used as a @main@ function, with
-- configurable defaults.
--
-- Example:
--
-- > import Criterion.Config
-- > import qualified Criterion.MultiMap as M
-- >
-- > myConfig = defaultConfig {
-- >              -- Always display an 800x600 window with curves.
-- >              cfgPlot = M.singleton KernelDensity (Window 800 600)
-- >            }
-- > 
-- > main = defaultMainWith myConfig [
-- >          bench "fib 30" $ B fib 30
-- >        ]
--
-- If you save the above example as @\"Fib.hs\"@, you should be able
-- to compile it as follows:
--
-- > ghc -O --make Fib
--
-- Run @\"Fib --help\"@ on the command line to get a list of command
-- line options.
defaultMainWith :: Config -> [Benchmark] -> IO ()
defaultMainWith defCfg bs = do
  (cfg, args) <- parseArgs defCfg defaultOptions =<< getArgs
  withConfig cfg $
   if cfgPrintExit cfg == List
    then do
      note "Benchmarks:\n"
      mapM_ (note "  %s\n") (sort $ concatMap benchNames bs)
    else do
      case getLast $ cfgSummaryFile cfg of
        Just fn -> liftIO $ writeFile fn "Name,Mean,MeanLB,MeanUB,Stddev,StddevLB,StddevUB\n"
        Nothing -> return ()
      env <- measureEnvironment
      let shouldRun b = null args || any (`isPrefixOf` b) args
      runAndAnalyse shouldRun env $ BenchGroup "" bs

-- | Display an error message from a command line parsing failure, and
-- exit.
parseError :: String -> IO a
parseError msg = do
  printError "Error: %s" msg
  printError "Run \"%s --help\" for usage information\n" =<< getProgName
  exitWith (ExitFailure 64)

-- $bench
--
-- The 'Benchmarkable' typeclass represents the class of all code that
-- can be benchmarked.  Every instance must run a benchmark a given
-- number of times.  We are most interested in benchmarking two things:
--
-- * 'IO' actions.  Any 'IO' action can be benchmarked directly.
--
-- * Pure functions.  GHC optimises aggressively when compiling with
--   @-O@, so it is easy to write innocent-looking benchmark code that
--   doesn't measure the performance of a pure function at all.  We
--   work around this by benchmarking both a function and its final
--   argument together.

-- $io
--
-- Any 'IO' action can be benchmarked easily if its type resembles
-- this:
--
-- @
-- 'IO' a
-- @

-- $pure
--
-- Because GHC optimises aggressively when compiling with @-O@, it is
-- potentially easy to write innocent-looking benchmark code that will
-- only be evaluated once, for which all but the first iteration of
-- the timing loop will be timing the cost of doing nothing.
--
-- To work around this, we provide two types for benchmarking pure
-- code.  The first is a specialised tuple:
--
-- @
-- data 'B' a = forall b. 'B' (a -> b) a
-- @
--
-- The second is a specialised tuple named 'B':
--
-- @
-- (a -> b, a)
-- @
--
-- As both of these types suggest, when you want to benchmark a
-- function, you must supply two values:
--
-- * The first element is the function, saturated with all but its
--   last argument.
--
-- * The second is the last argument to the function.
--
-- In practice, it is much easier to use the 'B' tuple than a normal
-- tuple.  Using 'B', the type checker can see when the function type
-- @a -> b@ and its argument type @a@ are the same, whereas code may
-- require an explicit type annotation to make this connection
-- explicit for a regular tuple.  Here is an example that makes the
-- distinction clearer.  Suppose we want to benchmark the following
-- function:
--
-- @
-- firstN :: Int -> [Int]
-- firstN k = take k [(0::Int)..]
-- @
--
-- So in the easy case, we construct a benchmark as follows:
--
-- @
-- 'B' firstN 1000
-- @
--
-- The compiler will correctly infer that the number 1000 must have
-- the type 'Int', and the type of the expression is
--
-- @
-- 'B' ['Int'] 'Int'
-- @
--
-- However, say we try to construct a benchmark using a tuple, as
-- follows:
--
-- @
-- (firstN, 1000)
-- @
--
-- Since we have written a numeric literal with no explicit type, the
-- compiler will correctly infer a rather general type for this
-- expression:
--
-- @
-- ('Num' a) => ('Int' -> ['Int'], a)
-- @
--
-- This does not match the type @(a -> b, a)@, so we would have to
-- explicitly annotate the number @1000@ as having the type @'Int'@
-- for the typechecker to accept this as a valid benchmarkable
-- expression.

-- $rnf
--
-- The harness for evaluating a pure function only evaluates the
-- result to weak head normal form (WHNF).  If you need the result
-- evaluated all the way to normal form, use the @rnf@ function from
-- the Control.Parallel.Strategies module to force its complete
-- evaluation.
--
-- Using the @firstN@ example from earlier, to naive eyes it /appears/
-- that the following code ought to benchmark the production of the
-- first 1000 list elements:
--
-- @
-- B firstN 1000
-- @
--
-- Because the result is only forced until WHNF is reached, what this
-- /actually/ benchmarks is merely the production of the first list
-- element!  Here is a corrected version:
--
-- @
-- B (rnf . firstN) 1000
-- @


