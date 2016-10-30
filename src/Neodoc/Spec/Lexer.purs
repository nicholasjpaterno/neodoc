module Neodoc.Spec.Lexer where

import Prelude
import Data.Array as A
import Debug.Profile
import Data.Pretty
import Data.Bifunctor (lmap)
import Data.NonEmpty (NonEmpty, (:|))
import Data.NonEmpty as NonEmpty
import Data.List as L
import Data.Tuple.Nested ((/\))
import Data.Monoid (mempty)
import Data.Functor (($>))
import Control.Alt ((<|>))
import Control.Apply ((*>), (<*))
import Control.Lazy (defer)
import Control.MonadPlus (guard)
import Data.Either (Either(..), fromRight)
import Data.Identity (Identity())
import Data.Foldable (foldMap)
import Control.Monad.State (StateT(..), State(..), evalState)
import Control.Monad.Except (ExceptT(..), throwError)
import Data.List (List(..), many, catMaybes, toUnfoldable, (:), some, reverse)
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.String (fromCharArray, trim, Pattern(..))
import Data.String (singleton, toUpper, split, joinWith) as String
import Data.String.Regex (Regex(), regex)
import Data.String.Regex (test, parseFlags, replace) as Regex
import Data.String.Ext ((^=), (~~))
import Partial.Unsafe (unsafePartial)
import Neodoc.Spec.Error (SpecParseError(..))

import Neodoc.Spec.Parser.Base as LEGACY
import Text.Parsing.Parser as LEGACY
import Text.Parsing.Parser.Combinators as LEGACY

import Text.Parsing.Parser.Pos (Position, initialPos) as P

import Neodoc.Spec.ParserState as ParserState
import Neodoc.Spec.ParserState (ParserState(..))

import Neodoc.ArgParser.Type (Parser(..), ParserArgs(..), Step(..))
import Neodoc.ArgParser.Type as P
import Neodoc.ArgParser.Combinators as P
import Neodoc.ArgParser.Combinators ((<?>), (<??>))
import Neodoc.ArgParser.Parsers.String (StringParserState)
import Neodoc.ArgParser.Parsers.String as P

data Mode = Usage | Descriptions

instance showMode :: Show Mode where
  show Usage        = "Usage"
  show Descriptions = "Descriptions"

type OptionArgument = {
  name     :: String
, optional :: Boolean
}

-- -- | Parser that parses a stream of tokens
-- type TokenParser a
--   = Parser
--       String
--       Unit
--       ParserState
--       Unit
--       (List PositionedToken)
--       a

-- | Parser that  parses a stream of tokens
type TokenParser a = LEGACY.ParserT (List PositionedToken) (State ParserState) a

-- | Parser that parses strings
type StringParser a
  = Parser
      String
      Unit
      StringParserState
      Unit
      String
      a

data PositionedToken = PositionedToken P.Position Token

instance prettyPositionedToken :: Pretty PositionedToken where
  pretty (PositionedToken _ tok) = pretty tok

instance showPositionedToken :: Show PositionedToken where
  show (PositionedToken pos tok) = "PositionedToken " <> show pos <> " " <> show  tok

data Token
  = LParen
  | RParen
  | LSquare
  | RSquare
  | Dash
  | VBar
  | Colon
  | Comma
  | Newline
  | TripleDot
  | Reference String
  | LOpt String (Maybe OptionArgument)
  | SOpt (NonEmpty Array Char) (Maybe OptionArgument)
  | Tag String String
  | Name String
  | ShoutName String
  | AngleName String
  | Garbage Char
  | DoubleDash

instance showToken :: Show Token where
  show = pretty --- XXX: TEMP

instance prettyToken :: Pretty Token where
  pretty LParen        = show '('
  pretty RParen        = show ')'
  pretty LSquare       = show '['
  pretty RSquare       = show ']'
  pretty Dash          = show '-'
  pretty VBar          = show '|'
  pretty Newline       = show '\n'
  pretty Colon         = show ':'
  pretty Comma         = show ','
  pretty TripleDot     = "..."
  pretty DoubleDash    = "--"
  pretty (Reference r) = "Reference " ~~ show r
  pretty (Garbage   c) = "Garbage "   ~~ show c
  pretty (Tag k v)     = "Tag "       ~~ show k ~~ " "  ~~ show v
  pretty (Name      n) = "Name "      ~~ show n
  pretty (ShoutName n) = "ShoutName " ~~ show n
  pretty (AngleName n) = "AngleName " ~~ show n
  pretty (LOpt n arg)  = "--" <> n <> arg'
    where arg' = fromMaybe "" do
                  arg <#> \a ->
                    if a.optional then "[" else ""
                      <> a.name
                      <> if a.optional then "]" else ""
  pretty (SOpt (c :| cs) arg) = "-" <> n <> arg'
    where n = fromCharArray $ A.cons c cs
          arg' = fromMaybe "" do
                  arg <#> \a ->
                    if a.optional then "[" else ""
                      <> a.name
                      <> if a.optional then "]" else ""

instance eqToken :: Eq Token where
  eq LParen            LParen             = true
  eq RParen            RParen             = true
  eq LSquare           LSquare            = true
  eq RSquare           RSquare            = true
  eq VBar              VBar               = true
  eq Colon             Colon              = true
  eq Comma             Comma              = true
  eq Dash              Dash               = true
  eq DoubleDash        DoubleDash         = true
  eq TripleDot         TripleDot          = true
  eq Newline           Newline            = true
  eq (Reference r)     (Reference r')     = r == r'
  eq (LOpt n arg)      (LOpt n' arg')
    = (n == n')
    && ((isNothing arg && isNothing arg')
        || (fromMaybe false do
              a  <- arg
              a' <- arg'
              pure $ (a.name == a'.name)
                  && (a.optional == a'.optional)
            ))
  eq (SOpt (c:|cs) arg) (SOpt (c':|cs') arg')
    = (c == c') && (cs == cs')
    && ((isNothing arg && isNothing arg')
        || (fromMaybe false do
              a  <- arg
              a' <- arg'
              pure $ (a.name == a'.name)
                  && (a.optional == a'.optional)
            ))
  eq (AngleName n)     (AngleName n')     = n == n'
  eq (ShoutName n)     (ShoutName n')     = n == n'
  eq (Name n)          (Name n')          = n == n'
  eq (Garbage c)       (Garbage c')       = c == c'
  eq _ _                                  = false


-- | Optimal: Faster P.skipSpaces since it does not accumulate into a list.
skipSpaces :: ∀ e c g. StringParser Unit
skipSpaces = (do
    P.satisfy \c -> c == '\n' || c == '\r' || c == ' ' || c == '\t'
    skipSpaces
  ) <|> pure unit

-- | Optimal: Translate [[<anything>-]options] to @anything
-- | this saves us looking ahead repeatedly when parsing '['.
referenceRegex :: Regex
referenceRegex
  = unsafePartial $ fromRight $
      regex
        "\\[(([^\\]](?!\\s*-?\\s*options\\s*))*?.?)\\s*-?\\s*options\\s*(\\.\\.\\.)?\\s*\\]"
        (Regex.parseFlags "gmi")

-- -- | Optimal: Typeclass-less bind instance
lex :: Mode -> String -> Either SpecParseError (List PositionedToken)
lex m input = profileS ("spec-parser::lex (" <> show m <> ")") \_->
  -- perform a simple transformation to avoid 'manyTill' and safe some millis
  -- lexing. Hopefully this won't be necessary when purescript-parsing improves
  -- performance, a faster parsing library shows up or the purescript compiler
  -- improves in performance.
  let input' = case m of
                Usage        -> Regex.replace referenceRegex "@$1" input
                Descriptions -> input
   in lmap (SpecParseError <<< (P.extractError id)) $
        P.runParser unit { position: P.initialPos } unit input' (parseTokens m)

lexDescs :: String -> Either SpecParseError (List PositionedToken)
lexDescs = lex Descriptions <<< trimDescSection

lexUsage :: String -> Either SpecParseError (List PositionedToken)
lexUsage = lex Usage

parseTokens :: Mode -> StringParser (L.List PositionedToken)
parseTokens m =
  let tokParser = case m of
                    Usage        -> parseUsageToken
                    Descriptions -> parseDescriptionToken
   in do
    skipSpaces
    xs <- many' $ parsePositionedToken tokParser
    P.eof <|> void do
      i <- P.getInput
      P.fail $ "Unexpected input: " <> i
    pure xs

-- optimal: tail recursive many' implementation specialized for lists
many' p = reverse <$> go Nil
  where go acc = do
          v <- P.option Nothing (Just <$> p)
          case v of
            Nothing -> pure acc
            Just v  -> go (v:acc)

-- optimal: tail recursive many' implementation specialized for arrays
manyA' p = A.fromFoldable <<< reverse <$> go Nil
  where go acc = do
          v <- P.option Nothing (Just <$> p)
          case v of
            Nothing -> pure acc
            Just v  -> go (v : acc)

parsePositionedToken :: StringParser Token -> StringParser PositionedToken
parsePositionedToken p = PositionedToken <$> P.getPosition <*> p

parseUsageToken :: StringParser Token
parseUsageToken = P.choice [
    P.char   '('   $> LParen
  , P.char   ')'   $> RParen
  , P.char   ']'   $> RSquare
  , P.char   '|'   $> VBar
  , P.char   ':'   $> Colon
  , P.char   ','   $> Comma
  , P.string "..." $> TripleDot
  , P.char   '['   $> LSquare
  , _reference
  , P.try _longOption
  , P.try _shortOption
  , P.try _eoa
  , _stdin
  , AngleName <$> _angleName
  , maybeShoutName
  ]
  <* skipSpaces -- skip spaces *AND* newlines

parseDescriptionToken :: StringParser Token
parseDescriptionToken = P.choice [
    P.char   ','   $> Comma
  , P.char   '('   $> LParen
  , P.char   ')'   $> RParen
  , P.char   ']'   $> RSquare
  , P.string "..." $> TripleDot
  , P.try _longOption
  , P.try _shortOption
  , AngleName <$> _angleName
  , maybeShoutName
  , P.try _tag
  , P.char '[' $> LSquare
  , _reference
  , P.eol $> Newline
  , Garbage <$> P.anyChar
  ]
  <* P.spaces -- skip only spaces ' ' and '\t'

maybeShoutNameRegex :: Regex
maybeShoutNameRegex
  = unsafePartial $ fromRight $
      regex "[a-zA-Z]" (Regex.parseFlags "gi")

maybeShoutName :: StringParser Token
maybeShoutName = do
  n <- _anyName
  pure if (String.toUpper n == n && Regex.test maybeShoutNameRegex n)
          then ShoutName n
          else Name n

_anyName :: StringParser String
_anyName = do
  foldMap String.singleton <$> do
    (:)
      <$> P.alphaNum
      <*> many' do
            P.choice [
              identLetter
            , P.oneOf [ '-', '_', '/' ]
            , P.try $ P.char '.' <* (P.notFollowedBy $ P.string "..")
          ]

white :: StringParser Unit
white = void $ P.oneOf [ '\n', '\r', ' ', '\t' ]

_stdin :: StringParser Token
_stdin = do
  P.char '-'
  -- Ensure the argument is correctly bounded
  P.eof <|> (P.lookAhead $ P.choice [
    void $ white
  , void $ P.char '|'
  , void $ P.char ']'
  , void $ P.char ')'
  , void $ P.string "..."
  ])
  pure Dash

_eoa :: StringParser Token
_eoa = do
  P.string "--"
  -- Ensure the argument is correctly bounded
  P.eof <|> (P.lookAhead $ P.choice [
    void $ white
  , void $ P.char ']'
  , void $ P.char ')'
  ])
  pure DoubleDash

_reference :: StringParser Token
_reference = Reference <$> do
  P.char '@'
  foldMap String.singleton <$> many' (P.noneOf [' ', '\n'])

_tag :: StringParser Token
_tag = P.between (P.char '[') (P.char ']') do
  s <- trim <<< foldMap String.singleton <$> some (P.noneOf [']'])
  case A.uncons (String.split (Pattern ":") s) of
    Nothing -> P.fail "Expected label"
    Just { head: _, tail: xs } | A.length xs == 0 ->  P.fail "Expected label"
    Just { head: x, tail: xs } ->
      let v = trim (String.joinWith ":" xs)
       in pure (Tag x v)

_angleName :: StringParser String
_angleName = do
  P.char '<'
  n <- foldMap String.singleton <$> do
    some $ P.choice [
      identLetter
      -- disallow swallowing new `<`s in order to avoid creating hard to trace
      -- errors for the user
    , P.noneOf [ '<', '>' ]
    ]
  P.char '>'
  pure $ "<" ~~ n ~~ ">"

_shortOption :: StringParser Token
_shortOption = do
  let validChar = P.alphaNum <|> P.oneOf [ '?' ]

  P.char '-'
  x  <- validChar
  xs <- manyA' validChar

  arg <- P.option Nothing $ P.choice [

    -- Case 1: -foo=BAR
    Just <$> do
      P.char '='
      name <- P.choice [ _angleName, _anyName ]
      pure  { name, optional: false }

    -- Case 2: Option[=ARG]
  , Just <$> do
      P.char '['
      P.optional $ P.char '='
      name <- P.choice [ _angleName, _anyName ]
      P.char ']'
      pure  { name, optional: true }

    -- Case 3: Option<ARG>
  , Just <$> do
      name <- _angleName
      pure { name, optional: false }
  ]

  -- Ensure the argument is correctly bounded
  P.eof <|> (P.lookAhead $ P.choice [
    void $ white
  , void $ P.char '|'
  , void $ P.string "..."
  , void $ P.char ']'
  , void $ P.char ')'
  , void $ P.char ',' -- desc mode only
  ])

  pure $ SOpt (x:|xs) arg

_longOption :: StringParser Token
_longOption = do
  P.string "--"

  name' <- foldMap String.singleton <$> do
    (:)
      <$> P.alphaNum
      <*> (many' $ P.choice [
            P.alphaNum
          , P.try $ P.char '.'
              <* (P.notFollowedBy $ P.string "..")
              <* P.lookAhead P.alphaNum
          , P.oneOf [ '-', '/' ] <* P.lookAhead P.alphaNum
          ])

  arg <- P.option Nothing $ P.choice [

    -- Case 1: OPTION=ARG
    Just <$> do
      P.char '='
      n <- P.choice [ _angleName, _anyName ]
      pure  { name: n
            , optional: false
            }

    -- Case 2: Option[=ARG]
  , Just <$> do
      P.char '['
      P.optional $ P.char '='
      n <- P.choice [ _angleName, _anyName ]
      P.char ']'
      pure  { name:     n
            , optional: true
            }
  ]

  -- Ensure the argument is correctly bounded
  P.eof <|> (P.lookAhead $ P.choice [
    void $ white
  , void $ P.char '|'
  , void $ P.string "..."
  , void $ P.char ']'
  , void $ P.char ')'
  , void $ P.char ',' -- desc mode only
  ])

  pure $ LOpt name' arg

identStart :: StringParser Char
identStart = P.alpha

identLetter :: StringParser Char
identLetter = P.alphaNum <|> P.oneOf ['_', '-']

flag :: StringParser Char
flag = P.lowerAlphaNum

-- token :: ∀ a. (Token -> Maybe a) -> TokenParser a
-- token test = Parser \(args@(ParseArgs _ _ _ toks)) ->
--   case toks of
--     (PositionedToken ppos tok):xs ->
--       case test tok of
--         Just a ->
--           let nextpos = case xs of
--                 (PositionedToken npos _):_ -> npos
--                 Nil -> ppos
--           in Step true (P.setI xs args) (Right a)
--         _ -> Step false args (Left (P.error "Token did not match predicate"))
--     _ -> Step false args (Left (P.error "Expected token, but met EOF"))

token :: ∀ a. (Token -> Maybe a) -> TokenParser a
token test = (LEGACY.ParserT <<< ExceptT <<< StateT) \(s@(LEGACY.ParseState toks pos _)) ->
  pure case toks of
    (PositionedToken ppos tok):xs ->
      case test tok of
        Just a ->
          let nextpos = case xs of
                (PositionedToken npos _):_ -> npos
                Nil -> ppos
          in (Right a) /\ (LEGACY.ParseState xs nextpos true)
        _ -> (Left (LEGACY.error "Token did not match predicate" pos false)) /\ s
    _ -> (Left (LEGACY.error "Expected token, but met EOF" pos false)) /\ s

-- | Match the token at the head of the stream
match :: Token -> TokenParser Unit
match tok = token (guard <<< (_ == tok)) <|> defer \_->
              LEGACY.fail $ "Expected " <> pretty tok

eof :: TokenParser Unit
eof = do
  toks <- LEGACY.getInput
  case toks of
    _:_ -> LEGACY.fail "Expected EOF"
    _   -> pure unit

anyToken :: TokenParser Token
anyToken = token Just

lparen :: TokenParser Unit
lparen = match LParen

rparen :: TokenParser Unit
rparen = match RParen

lsquare :: TokenParser Unit
lsquare = match LSquare

rsquare :: TokenParser Unit
rsquare = match RSquare

dash :: TokenParser Unit
dash = match Dash

doubleDash :: TokenParser Unit
doubleDash = match DoubleDash

vbar :: TokenParser Unit
vbar = match VBar

comma :: TokenParser Unit
comma = match Comma

colon :: TokenParser Unit
colon = match Colon

newline :: TokenParser Unit
newline = match Newline

tripleDot :: TokenParser Unit
tripleDot = match TripleDot

garbage :: TokenParser Unit
garbage = "garbage" LEGACY.<??> token go
  where
    go (Garbage _) = Just unit
    go _           = Nothing

lopt :: TokenParser { name :: String
                    , arg  :: Maybe OptionArgument
                    }
lopt = "long-option" LEGACY.<??> token go
  where
    go (LOpt n a) = Just { name: n, arg: a }
    go _          = Nothing

sopt :: TokenParser { chars :: NonEmpty Array Char
                    , arg   :: Maybe OptionArgument
                    }
sopt = "short-option" LEGACY.<??> token go
  where
    go (SOpt cs a) = Just { chars: cs , arg: a }
    go _ = Nothing

name :: TokenParser String
name = "name" LEGACY.<??> token go
  where
    go (Name n) = Just n
    go _        = Nothing

tag :: String -> TokenParser String
tag s = ("tag: " ~~ s) LEGACY.<??> token go
  where
    go (Tag k v) | k ^= s = Just v
    go _                  = Nothing

reference :: TokenParser String
reference = "reference" LEGACY.<??> token go
  where
    go (Reference r) = Just r
    go _             = Nothing

angleName :: TokenParser String
angleName = "<name>" LEGACY.<??> token go
  where
    go (AngleName n) = Just n
    go _             = Nothing

shoutName :: TokenParser String
shoutName = "NAME" LEGACY.<??> token go
  where
    go (ShoutName n) = Just n
    go _             = Nothing

-- | Return the next token's position w/o consuming anything
nextTokPos :: TokenParser P.Position
nextTokPos = do
  toks <- LEGACY.getInput
  case toks of
    (PositionedToken pos _):xs -> pure pos
    _                          -> LEGACY.fail "Expected token, met EOF"

-- runTokenParser
--   :: ∀ a
--    . List PositionedToken
--   -> TokenParser a
--   -> Either String a
-- runTokenParser s p = lmap (P.extractError id) do
--   P.runParser unit ParserState.initialState unit s p

runTokenParser
  :: ∀ a
   . List PositionedToken
  -> TokenParser a
  -> Either LEGACY.ParseError a
runTokenParser s =
  flip evalState ParserState.initialState
    <<< LEGACY.runParserT s

foreign import trimDescSection :: String -> String
