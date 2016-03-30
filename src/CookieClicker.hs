{-# LANGUAGE OverloadedStrings #-}
{-# Language ForeignFunctionInterface #-}
{-# Language RankNTypes #-}

module CookieClicker where

import GameInput
import Building
import SaveFormat
import SourceData

import Control.Monad (guard)
import Data.Text (Text)
import Debug.Trace
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe
import Control.Lens hiding (ReifiedPrism(..), prism)
import Numeric.Lens
import Data.List
import Data.Ord
import Data.Time
import Foreign.C.Types (CDouble(..))
import Numeric
import Control.Exception
import qualified Data.Text as Text

initialBuildingStat :: Double -> BuildingStat
initialBuildingStat base = BuildingStat
  { _bldgBase  = base
  , _bldgMult  = 1
  , _bldgBonus = 0
  , _bldgFree  = 0
  }

initialGameState :: GameState
initialGameState = GameState
  { _buildingStats           = initialBuildingStat <$> baseCps
  , _multiplier              = 1
  , _lateMultiplier          = 1
  , _eggMultiplier           = 1
  , _mouseBonus              = 0
  , _mouseMultiplier         = 1
  , _prestigeMultiplier      = 0
  , _bonusCps                = 0
  , _buildingCostMultiplier  = 1
  , _upgradeCostMultiplier   = 1
  , _milkMultiplier          = 1
  , _milkFactors             = []
  , _wrinklerMultiplier      = 1.1
  , _goldTimeMultiplier      = 1
  , _heartCookies            = 0
  , _heartCookieMultiplier   = 2
  , _cookieCostMultiplier    = 1
  }

baseCps :: Map Building Double
baseCps = Map.fromList
  [ (Cursor,              0.1e0)
  , (Grandma,             1.0e0)
  , (Farm,                8.0e0)
  , (Mine,               47.0e0)
  , (Factory,           260.0e0)
  , (Bank,                1.4e3)
  , (Temple,              7.8e3)
  , (WizardTower,        44.0e3)
  , (Shipment,          260.0e3)
  , (AlchemyLab,          1.6e6)
  , (Portal,             10.0e6)
  , (TimeMachine,        65.0e6)
  , (Antimatter,        430.0e6)
  , (Prism,              2.90e9)
  ]

initialCosts :: Map Building Double
initialCosts = Map.fromList
  [ (Cursor,             15.0e0)
  , (Grandma,           100.0e0)
  , (Farm,                1.1e3)
  , (Mine,               12.0e3)
  , (Factory,           130.0e3)
  , (Bank,              1.400e6)
  , (Temple,             20.0e6)
  , (WizardTower,       330.0e6)
  , (Shipment,            5.1e9)
  , (AlchemyLab,         75.0e9)
  , (Portal,             1.0e12)
  , (TimeMachine,       14.0e12)
  , (Antimatter,       170.0e12)
  , (Prism,              2.1e15)
  ]

upgradeEffect :: Upgrade -> Effect
upgradeEffect = views upgradeName effectByName

effectByName :: Text -> Effect
effectByName n =
  Map.findWithDefault
    (trace ("Unknown effect: " ++ Text.unpack n) noEffect)
    n
    upgradeEffects

computeGameState :: GameInput -> GameState
computeGameState input
  = effectByName (view dragonAura1 input) input
  $ effectByName (view dragonAura2 input) input
  $ foldl'
      (\acc u -> upgradeEffect u input acc)
      initialGameState
      (view upgradesBought input)

type Effect = GameInput -> GameState -> GameState

kittenBonus :: Double -> Effect
kittenBonus pct = \_ -> milkFactors %~ (pct/100:)

cookieBonus :: Int -> Effect
cookieBonus pct = \_ -> multiplier *~ (1+fromIntegral pct/100)

cursorAdd :: Double -> Effect
cursorAdd bonus = \inp ->
  let count = sum (Map.delete Cursor (view buildingsOwned inp))
  in buildingBonus Cursor +~ bonus * fromIntegral count

grandmaType :: Building -> Int -> Effect
grandmaType building count = \inp ->
    let bonus = fromIntegral (inp^.buildingOwned Grandma)
              / fromIntegral count
    in (buildingMult building *~ (1 + 0.01 * bonus))
     . (buildingMult Grandma  *~ 2)

doubler :: Building -> GameInput -> GameState -> GameState
doubler k _ = buildingMult k *~ 2

computeBuildingStatCps :: BuildingStat -> Double
computeBuildingStatCps stat = stat^.bldgBonus + stat^.bldgMult * stat^.bldgBase

computeBuildingCps :: GameState -> Map Building Double
computeBuildingCps st = computeBuildingStatCps <$> view buildingStats st

leftJoinWith' :: Ord k => (a -> b -> a) -> Map k a -> Map k b -> Map k a
leftJoinWith' f = Map.mergeWithKey (\_ x y -> Just $! f x y) id (\_ -> Map.empty)

buildingCosts :: GameInput -> GameState -> Map Building Double
buildingCosts inp st
  = fmap (* view buildingCostMultiplier st)
  $ leftJoinWith'
      (\base n -> base * 1.15 ^ max 0 n)
      initialCosts
      owned'
  where
  -- When you've sold your free buildings they don't
  -- get cheaper, hence the 'max 0' above
  owned' = leftJoinWith' (-)
             (view buildingsOwned inp)
             (view bldgFree <$> view buildingStats st)


data PayoffRow = PayoffRow
  { payoffName :: String
  , payoffCost :: !Double
  , payoffDelta :: !Double
  , payoffInput :: !GameInput
  , payoffIcon :: (Int,Int)
  }

payoff :: GameInput -> GameState -> [PayoffRow]
payoff inp st =
     [ PayoffRow
         { payoffName  = act
         , payoffCost  = cost
         , payoffDelta = delta / cps
         , payoffInput = i'
         , payoffIcon = icon
         }
     | (act, cost, f, icon)
            <- buyBuilding ++ buyUpgrades
            ++ buyGrandmas ++ buyUpgradeRequirements
            ++ buyAchievements
     , let i' = f inp
     , let delta = computeCps i' (computeGameState i') - cps
     , delta > 0
     ]

  where
  reserve = 6000 * cps

  buyBuilding =
    [( "+1 " ++ show x
     , cost
     , buildingOwned x .~ new
     , buildingIcons x
     )
    | (x, cost) <- Map.toList costs
    , let new = view (buildingOwned x) inp + 1
    -- only offer this if we aren't also 1 buy from an achievement
    , Just new /= fmap fst (Map.lookup x nextAchievements)
    ]

  buyUpgrades =
     [ ( views upgradeName Text.unpack u
       , computeUpgradeCost st u
       , upgradesBought %~ cons u
       , view upgradeIcon u
       )
     | u <- view upgradesAvailable inp
     ]

  buyGrandmas =
     [ finish 15 b up
     | view (buildingOwned Grandma) inp >= 1
     , (b, up) <- synergyGrandmas
     , view (buildingOwned b) inp < 15
     ]

  achievements = Set.fromList (map (view achievementName) (view achievementsEarned inp))
  costs = buildingCosts inp st
  cps   = computeCps inp st


  buyUpgradeRequirements =
     [ finish count b up
     | (b, (count, up) : _) <- Map.toList $
        Map.intersectionWith nextUpgrade (view buildingsOwned inp) upgradeRequirements
     ]

  nextAchievements
    = Map.mapMaybe candidate
    $ Map.intersectionWith
        nextUpgrade
        (view buildingsOwned inp)
        buildingAchievements
    where
    candidate m
      = listToMaybe
      $ do (count, aName) <- m
           guard (aName `Set.notMember` achievements)
           let a = Map.findWithDefault
                     (error ("Unknown achievement: " ++ Text.unpack aName))
                     aName
                     achievementByName
           return (count, a)

  buyAchievements =
    [ finishA count b a | (b, (count, a)) <- Map.toList nextAchievements ]

  nextUpgrade now options =
     [ (target, up)
         | (target, up) <- options
         , target > now
         , notElemOf (upgradesBought . folded . upgradeName) up inp
         ]

  finish :: Int -> Building -> Text -> (String, Double, GameInput -> GameInput, (Int,Int))
  finish n b up =
    ("+" ++ show n' ++ " " ++ show b ++ " + " ++ Text.unpack up, cost, f
    , view upgradeIcon u)
    where
    fa = case Map.lookup b nextAchievements of
      Just (count, a) | count <= n -> achievementsEarned %~ cons a
      _ -> id
    u = Map.findWithDefault (error ("Unknown upgrade: " ++ Text.unpack up))
               up
               upgradeByName
    n' = n - view (buildingOwned b) inp
    cost = view upgradeCost u + buyMore n' (costs ^?! ix b)
    f = (upgradesBought %~ cons u)
      . fa
      . (buildingOwned b .~ n)

  finishA n b a = ("+" ++ show n' ++ " " ++ show b, cost, f, buildingIcons b)
    where
    n' = n - view (buildingOwned b) inp
    cost = buyMore n' (costs ^?! ix b)
    f = (achievementsEarned %~ cons a)
      . (buildingOwned b .~ n)

computeUpgradeCost :: GameState -> Upgrade -> Double
computeUpgradeCost st u
  | view upgradePool u == "cookie" = view cookieCostMultiplier st * c
  | otherwise                      = c
  where
  c = view upgradeCost u
    * view upgradeCostMultiplier st

buyMore :: Int -> Double -> Double
buyMore count nextPrice
  | count < 0 = error "buyMore: negative count"
  | otherwise = nextPrice * (1 - 1.15 ^ count) / (1 - 1.15)

computeMultiplier :: GameInput -> GameState -> Double
computeMultiplier inp st
  = view multiplier st
  * view lateMultiplier st
  * milkFactor
  * view eggMultiplier st
  * prestigeFactor
  * heartFactor

  where
  milkFactor = product [ 1 + milk * x | x <- view milkFactors st ]
  milk = computeMilk inp * view milkMultiplier st

  prestigeFactor = 1 + view prestigeMultiplier st
                     * view prestigeLevel inp / 100
  heartFactor = (1 + view heartCookieMultiplier st / 100)
              ^ view heartCookies st

computeMilk :: GameInput -> Double
computeMilk input = fromIntegral n / 25
  where
  n = lengthOf (achievementsEarned . folded . filtered (views achievementPool (/= "shadow"))) input

computeCps :: GameInput -> GameState -> Double
computeCps inp st = computeMultiplier inp st * (view bonusCps st + buildingCps)
  where
  buildingCps
    = sum
    $ Map.intersectionWith
        (\count cps -> fromIntegral count * cps)
        (view buildingsOwned inp)
        (computeBuildingCps st)

computeClickCookies :: GameInput -> GameState -> Double
computeClickCookies inp st = view mouseMultiplier st * cpc
  where
  cpc = computeCps inp st * view mouseBonus st
      + view (buildingBonus Cursor) st
      + view (buildingMult Cursor) st

loadMyInput :: IO GameInput
loadMyInput =
  do now <- getCurrentTime
     saveFileToGameInput now <$> loadMySave



countUpgrades :: GameInput -> Int
countUpgrades = length . filter (views upgradePool validPool) . view upgradesBought
  where
  validPool "" = True
  validPool "tech" = True
  validPool "cookie" = True
  validPool _ = False

computeMunched :: GameInput -> GameState -> Double
computeMunched input st = view wrinklerMultiplier st * view cookiesMunched input

data SuffixLength = LongSuffix | ShortSuffix

prettyNumber :: SuffixLength -> Double -> String
prettyNumber s n
  | n < 1e6   = numberWithSeparators (showFFloat (Just 1) n "")
  | n < 1e9   = showFFloat (Just 3) (n / 1e6 ) (suffix " M" " million")
  | n < 1e12  = showFFloat (Just 3) (n / 1e9 ) (suffix " B" " billion")
  | n < 1e15  = showFFloat (Just 3) (n / 1e12) (suffix " T" " trillion")
  | n < 1e18  = showFFloat (Just 3) (n / 1e15) (suffix " Qa" " quadrillion")
  | n < 1e21  = showFFloat (Just 3) (n / 1e18) (suffix " Qi" " quintillion")
  | n < 1e24  = showFFloat (Just 3) (n / 1e21) (suffix " Sx" " sextillion")
  | n < 1e27  = showFFloat (Just 3) (n / 1e24) (suffix " Sp" " septillion")
  | n < 1e30  = showFFloat (Just 3) (n / 1e27) (suffix " Oc" " octillion")
  | n < 1e33  = showFFloat (Just 3) (n / 1e30) (suffix " No" " nonillion")
  | n < 1e36  = showFFloat (Just 3) (n / 1e33) (suffix " Dc" " decillion")
  | n < 1e39  = showFFloat (Just 3) (n / 1e36) (suffix " UnD" " undecillion")
  | n < 1e42  = showFFloat (Just 3) (n / 1e39) (suffix " DoD" " duodecillion")
  | n < 1e45  = showFFloat (Just 3) (n / 1e42) (suffix " TrD" " tredecillion")
  | n < 1e48  = showFFloat (Just 3) (n / 1e45) (suffix " QaD" " quattuordecillion")
  | otherwise = numberWithSeparators
              $ showFFloat (Just 3) (n / 1e48) (suffix " QiD" " quindecillion")
  where
  suffix short long =
    case s of
      ShortSuffix -> short
      LongSuffix  -> long

numberWithSeparators :: String -> String
numberWithSeparators str
  = case break ('.'==) str of
      (a,b) -> commas a ++ b
  where
  commas
    = reverse
    . intercalate ","
    . takeWhile (not . null)
    . map     (take 3)
    . iterate (drop 3)
    . reverse

prettyTime :: Integer -> String
prettyTime t = part y 'y' (y  > 0)
             $ part d 'd' (d' > 0)
             $ part h 'h' (h' > 0)
             $ part m 'm' (m' > 0)
             $ part s 's' True ""
  where
  (m',s) = quotRem t  60
  (h',m) = quotRem m' 60
  (d',h) = quotRem h' 24
  (y ,d) = quotRem d' 365

  part _ _ False = id
  part n c True  = shows n . showChar c

gpoc :: Building -> Double -> Effect
gpoc b bonus = \inp ->
  let gmas = views (buildingOwned b) fromIntegral inp
  in buildingBase Grandma +~ bonus * gmas

upgradeRequirements :: Map.Map Building [(Int, Text)]
upgradeRequirements = Map.fromList
   [ (Cursor,
      [ (1, "Reinforced index finger")
      , (1, "Carpal tunnel prevention cream")
      , (10, "Ambidextrous")
      , (20, "Thousand fingers")
      , (40, "Million fingers")
      , (80, "Billion fingers")
      , (120, "Trillion fingers")
      , (160, "Quadrillion fingers")
      , (200, "Quintillion fingers")
      , (240, "Sextillion fingers")
      , (280, "Septillion fingers")
      , (320, "Octillion fingers")
      ])
   , (Grandma,
      [ (1, "Forwards from grandma")
      , (5, "Steel-plated rolling pins")
      , (25, "Lubricated dentures")
      , (50, "Prune juice")
      , (100, "Double-thick glasses")
      , (150, "Aging agents")
      , (200, "Xtreme walkers")
      , (250, "The Unbridling")
      ])
   , (Farm,
      [ (1, "Cheap hoes")
      , (5, "Fertilizer")
      , (25, "Cookie trees")
      , (50, "Genetically-modified cookies")
      , (100, "Gingerbread scarecrows")
      , (150, "Pulsar sprinklers")
      , (200, "Fudge fungus")
      , (250, "Wheat triffids")
      ])
   , (Mine,
      [ (1, "Sugar gas")
      , (5, "Megadrill")
      , (25, "Ultradrill")
      , (50, "Ultimadrill")
      , (100, "H-bomb mining")
      , (150, "Coreforge")
      , (200, "Planetsplitters")
      , (250, "Canola oil wells")
      ])
   , (Factory,
      [ (1, "Sturdier conveyor belts")
      , (5, "Child labor")
      , (25, "Sweatshop")
      , (50, "Radium reactors")
      , (100, "Recombobulators")
      , (150, "Deep-bake process")
      , (200, "Cyborg workforce")
      , (250, "78-hour days")
      ])
   , (Bank,
      [ (1, "Taller tellers")
      , (5, "Scissor-resistant credit cards")
      , (25, "Acid-proof vaults")
      , (50, "Chocolate coins")
      , (100, "Exponential interest rates")
      , (150, "Financial zen")
      , (200, "Way of the wallet")
      , (250, "The stuff rationale")
      ])
   , (Temple,
      [ (1, "Golden idols")
      , (5, "Sacrifices")
      , (25, "Delicious blessing")
      , (50, "Sun festival")
      , (100, "Enlarged pantheon")
      , (150, "Great Baker in the sky")
      , (200, "Creation myth")
      , (250, "Theocracy")
      ])
   , (WizardTower,
      [ (1, "Pointier hats")
      , (5, "Beardlier beards")
      , (25, "Ancient grimoires")
      , (50, "Kitchen curses")
      , (100, "School of sorcery")
      , (150, "Dark formulas")
      , (200, "Cookiemancy")
      , (250, "Rabbit trick")
      ])
   , (Shipment,
      [ (1, "Vanilla nebulae")
      , (5, "Wormholes")
      , (25, "Frequent flyer")
      , (50, "Warp drive")
      , (100, "Chocolate monoliths")
      , (150, "Generation ship")
      , (200, "Dyson sphere")
      , (250, "The final frontier")
      ])
   , (AlchemyLab,
      [ (1, "Antimony")
      , (5, "Essence of dough")
      , (25, "True chocolate")
      , (50, "Ambrosia")
      , (100, "Aqua crustulae")
      , (150, "Origin crucible")
      , (200, "Theory of atomic fluidity")
      , (250, "Beige goo")
      ])
   , (Portal,
      [ (1, "Ancient tablet")
      , (5, "Insane oatling workers")
      , (25, "Soul bond")
      , (50, "Sanity dance")
      , (100, "Brane transplant")
      , (150, "Deity-sized portals")
      , (200, "End of times back-up plan")
      , (250, "Maddening chants")
      ])
   , (TimeMachine,
      [ (1, "Flux capacitors")
      , (5, "Time paradox resolver")
      , (25, "Quantum conundrum")
      , (50, "Causality enforcer")
      , (100, "Yestermorrow comparators")
      , (150, "Far future enactment")
      , (200, "Great loop hypothesis")
      , (250, "Cookietopian moments of maybe")
      ])
   , (Antimatter,
      [ (1, "Sugar bosons")
      , (5, "String theory")
      , (25, "Large macaron collider")
      , (50, "Big bang bake")
      , (100, "Reverse cyclotrons")
      , (150, "Nanocosmics")
      , (200, "The Pulse")
      , (250, "Some other super-tiny fundamental particle? Probably?")
      ])
   , (Prism,
      [ (1, "Gem polish")
      , (5, "9th color")
      , (25, "Chocolate light")
      , (50, "Grainbow")
      , (100, "Pure cosmic light")
      , (150, "Glow-in-the-dark")
      , (200, "Lux sanctorum")
      , (250, "Reverse shadows")
      ])
   ]

buildingAchievements :: Map Building [(Int, Text)]
buildingAchievements = Map.fromList
   [ (Cursor,
      [ (1, "Click")
      , (2, "Double-click")
      , (50, "Mouse wheel")
      , (100, "Of Mice and Men")
      , (200, "The Digital")
      , (300, "Extreme polydactyly")
      , (400, "Dr. T")
      , (500, "Thumbs, phalanges, metacarpals")
      ])
   , (Grandma,
      [ (1, "Grandma's cookies")
      , (50, "Sloppy kisses")
      , (100, "Retirement home")
      , (150, "Friend of the ancients")
      , (200, "Ruler of the ancients")
      , (250, "The old never bothered me anyway")
      , (300, "The agemaster")
      , (350, "To oldly go")
      ])
   , (Farm,
      [ (1, "My first farm")
      , (50, "Reap what you sow")
      , (100, "Farm ill")
      , (150, "Perfected agriculture")
      , (200, "Homegrown")
      , (250, "Gardener extraordinaire")
      , (300, "Seedy business")
      ])
   , (Factory,
      [ (1, "Production chain")
      , (50, "Industrial revolution")
      , (100, "Global warming")
      , (150, "Ultimate automation")
      , (200, "Technocracy")
      , (250, "Rise of the machines")
      , (300, "Modern times")
      ])
   , (Bank,
      [ (1, "Pretty penny")
      , (50, "Fit the bill")
      , (100, "A loan in the dark")
      , (150, "Need for greed")
      , (200, "It's the economy, stupid")
      , (250, "Acquire currency")
      , (300, "The nerve of war")
      ])
   , (Temple,
      [ (1, "Your time to shrine")
      , (50, "Shady sect")
      , (100, "New-age cult")
      , (150, "Organized religion")
      , (200, "Fanaticism")
      , (250, "Zealotry")
      , (300, "Wololo")
      ])
   , (WizardTower,
      [ (1, "Bewitched")
      , (50, "The sorcerer's apprentice")
      , (100, "Charms and enchantments")
      , (150, "Curses and maledictions")
      , (200, "Magic kingdom")
      , (250, "The wizarding world")
      , (300, "And now for my next trick, I'll need a volunteer from the audience")
      ])
   , (Shipment,
      [ (1, "Expedition")
      , (50, "Galactic highway")
      , (100, "Far far away")
      , (150, "Type II civilization")
      , (200, "We come in peace")
      , (250, "Parsec-masher")
      , (300, "It's not delivery")
      ])
   , (AlchemyLab,
      [ (1, "Transmutation")
      , (50, "Transmogrification")
      , (100, "Gold member")
      , (150, "Gild wars")
      , (200, "The secrets of the universe")
      , (250, "The work of a lifetime")
      , (300, "Gold, Jerry! Gold!")
      ])
   , (Portal,
      [ (1, "A whole new world")
      , (50, "Now you're thinking")
      , (100, "Dimensional shift")
      , (150, "Brain-split")
      , (200, "Realm of the Mad God")
      , (250, "A place lost in time")
      , (300, "Forbidden zone")
      ])
   , (TimeMachine,
      [ (1, "Time warp")
      , (50, "Alternate timeline")
      , (100, "Rewriting history")
      , (150, "Time duke")
      , (200, "Forever and ever")
      , (250, "Heat death")
      , (300, "cookie clicker forever and forever a hundred years cookie clicker, all day long forever, forever a hundred times, over and over cookie clicker adventures dot com")
      ])
   , (Antimatter,
      [ (1, "Antibatter")
      , (50, "Quirky quarks")
      , (100, "It does matter!")
      , (150, "Molecular maestro")
      , (200, "Walk the planck")
      , (250, "Microcosm")
      , (300, "Scientists baffled everywhere")
      ])
   , (Prism,
      [ (1, "Lone photon")
      , (50, "Dazzling glimmer")
      , (100, "Blinding flash")
      , (150, "Unending glow")
      , (200, "Rise and shine")
      , (250, "Bright future")
      , (300, "Harmony of the spheres")
      ])
   ]

upgradeEffects :: Map Text Effect
upgradeEffects = Map.fromList $
   [ (name, doubler b) | b <- [Grandma .. ], name <- buildingTieredUpgrades b ] ++
   [ (name, cookieBonus n) | (name, n) <- cookies ] ++
   [ (name, \_ -> heartCookies +~ 1) | name <- heartCookieNames ] ++
   [ (name, grandmaType b n) | (n,(b,name)) <- zip [1..] synergyGrandmas ] ++
   [ (name, \_ -> eggMultiplier +~ 0.01) | name <- regularEasterEggs ] ++
   [ (name, \_ -> mouseBonus +~ 0.01) | name <- mouseUpgrades ] ++

   [ ("Reinforced index finger"        , doubler Cursor)
   , ("Carpal tunnel prevention cream" , doubler Cursor)
   , ("Ambidextrous"                   , doubler Cursor)
   , ("Thousand fingers"               , cursorAdd 1.0e-1)
   , ("Million fingers"                , cursorAdd 5.0e-1)
   , ("Billion fingers"                , cursorAdd 5.0e+0)
   , ("Trillion fingers"               , cursorAdd 5.0e+1)
   , ("Quadrillion fingers"            , cursorAdd 5.0e+2)
   , ("Quintillion fingers"            , cursorAdd 5.0e+3)
   , ("Sextillion fingers"             , cursorAdd 5.0e+4)
   , ("Septillion fingers"             , cursorAdd 5.0e+5)
   , ("Octillion fingers"              , cursorAdd 5.0e+6)

   --    -- KITTENS
   , ("Kitten helpers"    , kittenBonus 10)
   , ("Kitten workers"    , kittenBonus 12.5)
   , ("Kitten engineers"  , kittenBonus 15)
   , ("Kitten overseers"  , kittenBonus 17.5)
   , ("Kitten managers"   , kittenBonus 20)
   , ("Kitten accountants", kittenBonus 20)
   , ("Kitten specialists", kittenBonus 20)
   , ("Kitten experts"    , kittenBonus 20)
   , ("Kitten angels"     , kittenBonus 10)

   --    -- COOKIES

   , ("Lucky day"  , noEffect)
   , ("Serendipity", noEffect)
   , ("Get lucky"  , \_ -> goldTimeMultiplier *~ 2)

   , ("Bingo center/Research facility", \_ -> buildingMult Grandma *~ 4)
   , ("Specialized chocolate chips"   , cookieBonus 1)
   , ("Designer cocoa beans"          , cookieBonus 2)
   , ("Ritual rolling pins"           , doubler Grandma)
   , ("Underworld ovens"              , cookieBonus 3)
   , ("One mind"                      , gpoc Grandma 0.02)
   , ("Exotic nuts"                   , cookieBonus 4)
   , ("Communal brainsweep"           , gpoc Grandma 0.02)
   , ("Arcane sugar"                  , cookieBonus 5)
   , ("Elder Pact"                    , gpoc Portal 0.05)
   , ("Sacrificial rolling pins"      , noEffect)

   , ("Century egg"  , addEggTimeBonus)
   , ("Cookie egg"   , \_ -> mouseMultiplier *~ 1.1)
   , ("Wrinklerspawn", \_ -> wrinklerMultiplier *~ 1.05)

   , ("Faberge egg", \_ -> (buildingCostMultiplier *~ 0.99)
                         . (upgradeCostMultiplier  *~ 0.99) )
   , ("\"egg\"", \_ -> bonusCps +~ 9)
   , ("Omelette", noEffect)

   , ("A crumbly egg", noEffect)

   , ("Heavenly chip secret"  , prestigeBonus 5)
   , ("Heavenly cookie stand" , prestigeBonus 20)
   , ("Heavenly bakery"       , prestigeBonus 25)
   , ("Heavenly confectionery", prestigeBonus 25)
   , ("Heavenly key"          , prestigeBonus 25)

   , ("A festive hat"             , noEffect)
   , ("Increased merriness"       , cookieBonus 15)
   , ("Improved jolliness"        , cookieBonus 15)
   , ("A lump of coal"            , cookieBonus 1)
   , ("An itchy sweater"          , cookieBonus 1)
   , ("Reindeer baking grounds"   , noEffect)
   , ("Weighted sleds"            , noEffect)
   , ("Ho ho ho-flavored frosting", noEffect)
   , ("Season savings"            , \_ -> buildingCostMultiplier *~ 0.99)
   , ("Toy workshop"              , \_ -> upgradeCostMultiplier *~ 0.95)
   , ("Naughty list"              , doubler Grandma)
   , ("Santa's bottomless bag"    , noEffect) -- drops
   , ("Santa's helpers"           , \_ -> mouseMultiplier *~ 1.1)
   , ("Santa's legacy"            , cookieBonus (15*3)) -- assumes max level 15
   , ("Santa's milk and cookies"  , \_ -> milkMultiplier *~ 1.05)
   , ("Santa's dominion"          , \inp -> cookieBonus 20 inp
                                         . (buildingCostMultiplier *~ 0.99)
                                         . (upgradeCostMultiplier *~ 0.98))

   , ("Future almanacs"             , synergy Farm        TimeMachine)
   , ("Seismic magic"               , synergy Mine        WizardTower)
   , ("Quantum electronics"         , synergy Factory     Antimatter )
   , ("Contracts from beyond"       , synergy Bank        Portal     )
   , ("Paganism"                    , synergy Temple      Portal     )
   , ("Arcane knowledge"            , synergy WizardTower AlchemyLab )
   , ("Fossil fuels"                , synergy Mine        Shipment   )
   , ("Primordial ores"             , synergy Mine        AlchemyLab )
   , ("Infernal crops"              , synergy Farm        Portal     )
   , ("Extra physics funding"       , synergy Bank        Antimatter )
   , ("Relativistic parsec-skipping", synergy Shipment    TimeMachine)
   , ("Light magic"                 , synergy WizardTower Prism      )

   , ("Rain prayer"                 , synergy Farm        Temple     )
   , ("Asteroid mining"             , synergy Mine        Shipment   )
   , ("Temporal overclocking"       , synergy Factory     TimeMachine)
   , ("Printing presses"            , synergy Factory     Bank       )
   , ("God particle"                , synergy Temple      Antimatter )
   , ("Magical botany"              , synergy Farm        WizardTower)
   , ("Shipyards"                   , synergy Factory     Shipment   )
   , ("Gold fund"                   , synergy Bank        AlchemyLab )
   , ("Abysmal glimmer"             , synergy Portal      Prism      )
   , ("Primeval glow"               , synergy TimeMachine Prism      )
   , ("Chemical proficiency"        , synergy AlchemyLab  Antimatter )
   , ("Mystical energies"           , synergy Temple      Prism      )

   , ("Revoke Elder Covenant"      , noEffect)
   , ("Persistent memory"          , noEffect)
   , ("Weighted sleighs"           , noEffect)
   , ("Season switcher"            , noEffect)
   , ("Bunny biscuit"              , noEffect)
   , ("Tin of british tea biscuits", noEffect)
   , ("Box of macarons"            , noEffect)
   , ("Box of brand biscuits"      , noEffect)
   , ("Permanent upgrade slot I"   , noEffect)
   , ("Permanent upgrade slot II"  , noEffect)
   , ("Permanent upgrade slot III" , noEffect)
   , ("Permanent upgrade slot IV"  , noEffect)
   , ("Permanent upgrade slot V"   , noEffect)
   , ("Angels"                     , noEffect)
   , ("Archangels"                 , noEffect)
   , ("Virtues"                    , noEffect)
   , ("Dominions"                  , noEffect)
   , ("Cherubim"                   , noEffect)
   , ("Asmodeus"                   , noEffect)
   , ("Seraphim"                   , noEffect)
   , ("Beelzebub"                  , noEffect)
   , ("Halo gloves"                , \_ -> mouseMultiplier *~ 1.1)
   , ("Unholy bait"                , noEffect)
   , ("Twin Gates of Transcendence", noEffect)
   , ("Heavenly luck"              , noEffect)
   , ("Lasting fortune"            , \_ -> goldTimeMultiplier *~ 1.1)
   -- , ("Residual luck"              , _) XXX: +10% golden switch bonus per each ['Get lucky','Lucky day','Serendipity','Heavenly luck','Lasting fortune','Decisive fate'];

   , ("Starter kit"    , \_ -> buildingFree Cursor  +~ 10)
   , ("Starter kitchen", \_ -> buildingFree Grandma +~  5)

   , ("How to bake your dragon", noEffect)
   , ("Tin of butter cookies"  , noEffect)
   , ("Golden switch"          , noEffect) -- enables the switch
   , ("Classic dairy selection", noEffect)
   , ("Belphegor"              , noEffect)
   , ("Mammon"                 , noEffect)
   , ("Abaddon"                , noEffect)
   , ("Satan"                  , noEffect)
   , ("Legacy"                 , noEffect)
   , ("Synergies Vol. I"       , noEffect)
   , ("Synergies Vol. II"      , noEffect)
   , ("Elder Pledge"           , noEffect)
   , ("Elder Covenant"         , noEffect)
   , ("Festive biscuit"        , noEffect)
   , ("Ghostly biscuit"        , noEffect)
   , ("Lovesick biscuit"       , noEffect)
   , ("Fool's biscuit"         , noEffect)
   , ("Golden switch [off]"    , \_ -> lateMultiplier *~ 2.1)
   , ("Golden switch [on]"     , noEffect)
   , ("Milk selector"          , noEffect)
   , ("Golden goose egg"       , noEffect)
   , ("Chocolate egg"          , noEffect)
   , ("Decisive fate"          , noEffect)

   -- Dragon Auras
   , ("No aura"         , noEffect)
   , ("Breath of Milk", \_ -> milkMultiplier *~ 1.05 )
   , ("Radiant Appetite", cookieBonus 100)
   , ("Earth Shatterer",  noEffect)
   , ("Dragonflight"    , noEffect) -- effect not modeled
   , ("Mind Over Matter", noEffect) -- 0.75 multiplier to random drops

   , ("Divine discount", \_ -> buildingCostMultiplier *~ 0.99)
   , ("Divine sales", \_ -> upgradeCostMultiplier *~ 0.99)
   , ("Divine bakeries", \_ -> cookieCostMultiplier /~ 5)

   , ("Five-finger discount", fiveFingers)

   , ("Elder spice", noEffect)
   , ("Sacrilegious corruption", \_ -> wrinklerMultiplier *~ 1.05)

   , ("Starterror", noEffect)
   , ("Starspawn", noEffect)
   , ("Starsnow", noEffect)
   , ("Starlove", \_ -> heartCookieMultiplier *~ 1.5) -- XXX: affects heart cookies
   , ("Startrade", noEffect)

   , ("Golden cookie alert sound", noEffect)
   , ("Golden cookie sound selector", noEffect)
   ]

synergyGrandmas :: [(Building, Text)]
synergyGrandmas =
  [ (Farm       , "Farmer grandmas")
  , (Mine       , "Miner grandmas")
  , (Factory    , "Worker grandmas")
  , (Bank       , "Banker grandmas")
  , (Temple     , "Priestess grandmas")
  , (WizardTower, "Witch grandmas")
  , (Shipment   , "Cosmic grandmas")
  , (AlchemyLab , "Transmuted grandmas")
  , (Portal     , "Altered grandmas")
  , (TimeMachine, "Grandmas' grandmas")
  , (Antimatter , "Antigrandmas")
  , (Prism      , "Rainbow grandmas")
  ]

mouseUpgrades :: [Text]
mouseUpgrades =
  ["Plastic mouse", "Iron mouse", "Titanium mouse", "Adamantium mouse",
   "Unobtainium mouse", "Eludium mouse", "Wishalloy mouse", "Fantasteel mouse",
   "Nevercrack mouse"]


heartCookieNames :: [Text]
heartCookieNames =
   [ "Pure heart biscuits"
   , "Ardent heart biscuits"
   , "Sour heart biscuits"
   , "Weeping heart biscuits"
   , "Golden heart biscuits"
   , "Eternal heart biscuits"
   ]

regularEasterEggs :: [Text]
regularEasterEggs =
  ["Salmon roe" ,"Ant larva" ,"Cassowary egg", "Duck egg",
   "Turkey egg" ,"Turtle egg", "Quail egg", "Robin egg",
   "Ostrich egg", "Shark egg", "Chicken egg", "Frogspawn"]

-- | Cookies with a constant power effect
cookies :: [(Text, Int)]
cookies =
   [ (view upgradeName u, n)
       | u <- upgradeById
       , "cookie" == view upgradePool u
       , Just n <- [view upgradePower u]
       ]

buildingTieredUpgrades :: Building -> [Text]
buildingTieredUpgrades b =
  case b of
    Cursor -> []

    Grandma -> [ "Forwards from grandma", "Steel-plated rolling pins",
                 "Lubricated dentures", "Prune juice", "Double-thick glasses",
                 "Aging agents", "Xtreme walkers", "The Unbridling"]

    Farm -> [ "Cheap hoes", "Fertilizer", "Cookie trees",
              "Genetically-modified cookies", "Gingerbread scarecrows",
              "Pulsar sprinklers", "Fudge fungus", "Wheat triffids"]

    Mine -> [ "Sugar gas", "Megadrill", "Ultradrill", "Ultimadrill",
              "H-bomb mining", "Coreforge", "Planetsplitters",
              "Canola oil wells"]

    Factory -> [ "Sturdier conveyor belts", "Child labor", "Sweatshop",
                 "Radium reactors", "Recombobulators", "Deep-bake process",
                 "Cyborg workforce", "78-hour days" ]

    Bank -> [ "Taller tellers", "Scissor-resistant credit cards",
              "Acid-proof vaults", "Chocolate coins",
              "Exponential interest rates", "Financial zen",
              "Way of the wallet", "The stuff rationale" ]

    Temple -> [ "Golden idols", "Sacrifices", "Delicious blessing",
                "Sun festival", "Enlarged pantheon", "Great Baker in the sky",
                "Creation myth", "Theocracy" ]

    WizardTower -> [ "Pointier hats", "Beardlier beards", "Ancient grimoires",
                     "Kitchen curses", "School of sorcery", "Dark formulas",
                     "Cookiemancy", "Rabbit trick" ]

    Shipment -> [ "Vanilla nebulae", "Wormholes", "Frequent flyer",
                  "Warp drive", "Chocolate monoliths", "Generation ship",
                  "Dyson sphere", "The final frontier" ]

    AlchemyLab -> [ "Antimony", "Essence of dough", "True chocolate",
                    "Ambrosia", "Aqua crustulae", "Origin crucible",
                    "Theory of atomic fluidity", "Beige goo" ]

    Portal -> [ "Ancient tablet", "Insane oatling workers", "Soul bond",
                "Sanity dance", "Brane transplant", "Deity-sized portals",
                "End of times back-up plan", "Maddening chants" ]

    TimeMachine -> [ "Flux capacitors", "Time paradox resolver",
                     "Quantum conundrum", "Causality enforcer",
                     "Yestermorrow comparators", "Far future enactment",
                     "Great loop hypothesis", "Cookietopian moments of maybe" ]

    Antimatter -> [ "Sugar bosons", "String theory", "Large macaron collider",
                    "Big bang bake", "Reverse cyclotrons", "Nanocosmics",
                    "The Pulse",
                    "Some other super-tiny fundamental particle? Probably?" ]

    Prism -> [ "Gem polish", "9th color", "Chocolate light", "Grainbow",
               "Pure cosmic light", "Glow-in-the-dark", "Lux sanctorum" ,
               "Reverse shadows" ]

noEffect :: Effect
noEffect _ st = st

prestigeBonus :: Double -> Effect
prestigeBonus n _ = prestigeMultiplier +~ n / 100

addEggTimeBonus :: Effect
addEggTimeBonus inp = eggMultiplier +~ views sessionLength eggTimeBonus inp

eggTimeBonus ::
  Double {- ^ current session duration in seconds -} ->
  Double {- ^ cookie production multiplier        -}
eggTimeBonus s = (1 - (1 - cappedDays/100)**3) / 10
  where
  secPerDay = 60 * 60 * 24

  -- this bonus increases in units of 10 seconds
  steppedSeconds = under (multiplying 10) floor' s

  days = steppedSeconds / secPerDay

  -- The benefit maxes out at 100 days
  cappedDays = min 100 days

floor' :: Double -> Double
floor' = realToFrac . c_floor . realToFrac

ceil' :: Double -> Double
ceil' = realToFrac . c_ceil . realToFrac

foreign import ccall "math.h floor" c_floor :: CDouble -> CDouble
foreign import ccall "math.h ceil" c_ceil :: CDouble -> CDouble

synergy :: Building -> Building -> Effect
synergy major minor inp
  = assert (major < minor)
  $ (buildingMult major *~ (1 + 0.050 * fromIntegral minorCount))
  . (buildingMult minor *~ (1 + 0.001 * fromIntegral majorCount))
  where
  majorCount = view (buildingOwned major) inp
  minorCount = view (buildingOwned minor) inp


saveFileToGameInput :: UTCTime -> SaveFile -> GameInput
saveFileToGameInput now sav = GameInput
  { _buildingsOwned     = bldgCurrent <$> savBuildings sav
  , _achievementsEarned = achievements
  , _upgradesBought     = upgradeList snd
  , _upgradesAvailable  = upgradeList inShop
  , _prestigeLevel      = savPrestige (savMain sav)
  , _sessionLength      = duration
  , _cookiesMunched     = savMunched (savMain sav)
  , _wrinklers          = savWrinklers (savMain sav)
  , _cookiesBanked      = savCookies (savMain sav)
  , _dragonAura1        = dragonAuras !! savDragonAura (savMain sav)
  , _dragonAura2        = dragonAuras !! savDragonAura2 (savMain sav)

  , _cookiesForfeit     = savCookiesReset  (savMain sav)
  , _cookiesEarned      = savCookiesEarned (savMain sav)
  , _heavenlyChips      = savHeavenlyChips (savMain sav)
  }
  where
  duration = realToFrac (diffUTCTime now (savSessionStart (savStats sav)))

  inShop (unlocked,bought) = unlocked && not bought

  upgradeList f
     = fmap (upgradeById !!)
     $ findIndices f
     $ savUpgrades sav

  achievements
    = fmap (achievementById !!)
    $ findIndices id
    $ savAchievements sav

sellOff :: GameInput -> GameState -> Double
sellOff input st = view buildingCostMultiplier st * sums
  where
  cost1 n p = sum $ take n $ iterate (*1.15) p

  sums = sum $ Map.intersectionWith cost1 owned initialCosts

  owned = leftJoinWith' (-)
                (view buildingsOwned input)
                (view bldgFree <$> view buildingStats st)

computeElderFrenzyTime :: GameState -> Double
computeElderFrenzyTime st = ceil' (6 * view goldTimeMultiplier st)

-- | Compute cookies needed in bank to maximize the wrath-cookie chain
-- payout based on current cookies per second.
cpsToChainReserve6 ::
  Double {- ^ cookies per second -} ->
  Double {- ^ cookies to bank    -}
cpsToChainReserve6 cps = 4 * floor6 (6 * hours * cps)
  where
  hours = 60 * 60

floor6 :: Double -> Double
floor6 = under (powering 10 . multiplying (2/3)) (max 1 . floor')
--var maxPayout=Math.min(Game.cookiesPs*60*60*6,Game.cookies*0.25)*mult;

-- | Isomorphism between prestige level and cookies baked.
--
-- @
-- prestigeLevel = cookies**3 * 1e12
-- prestigeLevel = _Prestige # cookies
-- @
_Prestige :: Iso' Double Double
_Prestige = multiplying 1e4 . exponentiating 3


-- | Compute the cost to buy back the given number of buildings
-- after sacrificing that many for Krumblor, the cookie dragon.
sacrificeCost :: Int -> GameInput -> GameState -> Double
sacrificeCost n i st = sum (buyMore n <$> buildingCosts i' st)
  where
  i' = over (buildingsOwned . mapped) (subtract n) i

bigStep :: GameInput -> [String]
bigStep i
  | payoffCost best <= view cookiesBanked i = payoffName best
                                            : bigStep (payoffInput best & cookiesBanked -~ payoffCost best)
  | otherwise = []
  where
  best = minimumBy (comparing metric)
       $ filter isBuyOne
       $ payoff i (computeGameState i)

  metric x = payoffCost x * payoffDelta x

  isBuyOne x = "+1 " `isPrefixOf` payoffName x

computeWrinklerEffect :: GameInput -> GameState -> Double
computeWrinklerEffect input st =
  (1 - wither) + wither * view wrinklerMultiplier st * n
               / view lateMultiplier st
  where
  n = views wrinklers fromIntegral input
  wither = n * 0.05

buildingIcons :: Building -> (Int,Int)
buildingIcons Cursor = (0,0)
buildingIcons Grandma = (1,0)
buildingIcons Farm = (2,0)
buildingIcons Mine = (3,0)
buildingIcons Factory = (4,0)
buildingIcons Shipment = (5,0)
buildingIcons AlchemyLab = (6,0)
buildingIcons Portal = (7,0)
buildingIcons TimeMachine = (8,0)
buildingIcons Antimatter = (13,0)
buildingIcons Prism = (14,0)
buildingIcons Bank = (15,0)
buildingIcons Temple = (16,0)
buildingIcons WizardTower = (17,0)

fiveFingers :: Effect
fiveFingers inp =
  upgradeCostMultiplier *~ 0.99**(fromIntegral cursors/ 100)
  where
  cursors = view (buildingOwned Cursor) inp

------------------------------------------------------------------------
-- Missing functions from lens
------------------------------------------------------------------------

-- | Divide a number identified by a setter by a divisor.
(/~) :: Fractional a => ASetter' s a -> a -> s -> s
l /~ x = over l (/ x)
{-# INLINE (/~) #-}

-- | The isomorphism between the power function and the log function
-- at a given base.
--
-- @
-- powering base = iso (base **) (logBase base)
-- @
powering :: Floating a => a -> Iso' a a
powering base = iso (base **) (logBase base)
