{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Minimal JSON codec for the KBeacon Pro configuration protocol.
--
-- The beacon speaks small JSON messages over GATT ("msg":"getPara",
-- "msg":"cfg", see KBeacon.Protocol). We only need to generate a few
-- fixed message shapes and read a handful of fields out of the
-- responses.
--
-- Decision: a hand-written ~200 line codec instead of aeson.
-- Alternatives considered: aeson (drags in scientific, vector,
-- unordered-containers and Template Haskell machinery, all of which
-- must cross-compile for Android aarch64/armv7a AND build with the
-- mac2ios pipeline; the async/vector cross-compilation history in
-- hatter shows each extra dependency is a real risk) and
-- string-concatenation only (fine for generating, but the getPara
-- response must actually be parsed to learn the slot type and battery
-- percent). The protocol's JSON is tiny (< 4096 bytes by firmware
-- limit) and machine-generated, so a small verified codec is the
-- boring option.
module KBeacon.Json
  ( JsonValue(..)
  , parseJson
  , renderJson
  , lookupField
  , jsonInt
  , jsonNumberFromInt
  , jsonText
  , jsonArrayItems
  ) where

import Data.Char (chr, isDigit, isHexDigit, ord)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Unwitch.Convert.Int qualified as Int
import Unwitch.Convert.Integer qualified as Integer

-- | A parsed JSON document. Numbers are kept as 'Double'; every
-- numeric field in the KBeacon protocol (advPrd, btPt, slot, type)
-- fits a Double exactly.
data JsonValue
  = JsonObject [(Text, JsonValue)]
  | JsonArray [JsonValue]
  | JsonString Text
  | JsonNumber Double
  | JsonBool Bool
  | JsonNull
  deriving (Show, Eq)

-- | Parse a complete JSON document. Trailing whitespace is allowed,
-- any other trailing content is an error.
parseJson :: Text -> Either Text JsonValue
parseJson input = do
  (value, rest) <- parseValue (skipSpace input)
  if Text.null (skipSpace rest)
    then Right value
    else Left ("trailing content after JSON document: " <> Text.take 40 rest)

-- | Skip JSON whitespace.
skipSpace :: Text -> Text
skipSpace = Text.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n' || c == '\r')

-- | Parse one JSON value from the front of the input.
parseValue :: Text -> Either Text (JsonValue, Text)
parseValue input =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input, expected a JSON value"
    Just (c, rest) -> if
      | c == '{' -> parseObject (skipSpace rest) []
      | c == '[' -> parseArray (skipSpace rest) []
      | c == '"' -> do
          (string, afterString) <- parseStringBody rest []
          Right (JsonString string, afterString)
      | c == 't' -> parseKeyword "true" (JsonBool True) input
      | c == 'f' -> parseKeyword "false" (JsonBool False) input
      | c == 'n' -> parseKeyword "null" JsonNull input
      | c == '-' || isDigit c -> parseNumber input
      | otherwise -> Left ("unexpected character " <> Text.singleton c)

-- | Parse a fixed keyword (true/false/null).
parseKeyword :: Text -> JsonValue -> Text -> Either Text (JsonValue, Text)
parseKeyword keyword value input =
  case Text.stripPrefix keyword input of
    Just rest -> Right (value, rest)
    Nothing   -> Left ("expected keyword " <> keyword)

-- | Parse a JSON number using text's double reader (accepts the JSON
-- grammar's integer, fraction and exponent forms).
parseNumber :: Text -> Either Text (JsonValue, Text)
parseNumber input =
  case TextRead.signed TextRead.double input of
    Left err -> Left ("invalid number: " <> Text.pack err)
    Right (number, rest) -> Right (JsonNumber number, rest)

-- | Parse object members after the opening brace (input already
-- space-skipped). Accumulates members in reverse.
parseObject :: Text -> [(Text, JsonValue)] -> Either Text (JsonValue, Text)
parseObject input accumulated =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input inside object"
    Just (c, rest) -> if
      | c == '}' -> Right (JsonObject (reverse accumulated), rest)
      | c == '"' -> do
          (key, afterKey) <- parseStringBody rest []
          afterColon <- expectChar ':' (skipSpace afterKey)
          (value, afterValue) <- parseValue (skipSpace afterColon)
          parseObjectSeparator (skipSpace afterValue) ((key, value) : accumulated)
      | otherwise -> Left ("expected '\"' or '}' in object, got " <> Text.singleton c)

-- | After an object member: a comma continues, a brace closes.
parseObjectSeparator :: Text -> [(Text, JsonValue)] -> Either Text (JsonValue, Text)
parseObjectSeparator input accumulated =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input inside object"
    Just (c, rest) -> if
      | c == ',' -> parseObjectMember (skipSpace rest) accumulated
      | c == '}' -> Right (JsonObject (reverse accumulated), rest)
      | otherwise -> Left ("expected ',' or '}' in object, got " <> Text.singleton c)

-- | Parse the member that must follow a comma inside an object.
parseObjectMember :: Text -> [(Text, JsonValue)] -> Either Text (JsonValue, Text)
parseObjectMember input accumulated =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input inside object"
    Just (c, rest) -> if
      | c == '"' -> do
          (key, afterKey) <- parseStringBody rest []
          afterColon <- expectChar ':' (skipSpace afterKey)
          (value, afterValue) <- parseValue (skipSpace afterColon)
          parseObjectSeparator (skipSpace afterValue) ((key, value) : accumulated)
      | otherwise -> Left ("expected '\"' after ',' in object, got " <> Text.singleton c)

-- | Parse array items after the opening bracket (input already
-- space-skipped). Accumulates items in reverse.
parseArray :: Text -> [JsonValue] -> Either Text (JsonValue, Text)
parseArray input accumulated =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input inside array"
    Just (c, rest) -> if
      | c == ']' && null accumulated -> Right (JsonArray [], rest)
      | otherwise -> do
          (value, afterValue) <- parseValue input
          parseArraySeparator (skipSpace afterValue) (value : accumulated)

-- | After an array item: a comma continues, a bracket closes.
parseArraySeparator :: Text -> [JsonValue] -> Either Text (JsonValue, Text)
parseArraySeparator input accumulated =
  case Text.uncons input of
    Nothing -> Left "unexpected end of input inside array"
    Just (c, rest) -> if
      | c == ',' -> do
          (value, afterValue) <- parseValue (skipSpace rest)
          parseArraySeparator (skipSpace afterValue) (value : accumulated)
      | c == ']' -> Right (JsonArray (reverse accumulated), rest)
      | otherwise -> Left ("expected ',' or ']' in array, got " <> Text.singleton c)

-- | Require a specific character at the front of the input.
expectChar :: Char -> Text -> Either Text Text
expectChar expected input =
  case Text.uncons input of
    Just (c, rest) ->
      if c == expected
        then Right rest
        else Left ("expected '" <> Text.singleton expected <> "', got " <> Text.singleton c)
    Nothing -> Left ("unexpected end of input, expected '" <> Text.singleton expected <> "'")

-- | Parse a string body after the opening quote. Accumulates chunks
-- in reverse.
parseStringBody :: Text -> [Text] -> Either Text (Text, Text)
parseStringBody input accumulated =
  let (plain, rest) = Text.break (\c -> c == '"' || c == '\\') input
  in case Text.uncons rest of
    Nothing -> Left "unterminated string"
    Just ('"', afterQuote) ->
      Right (Text.concat (reverse (plain : accumulated)), afterQuote)
    Just ('\\', afterBackslash) -> do
      (unescaped, afterEscape) <- parseEscape afterBackslash
      parseStringBody afterEscape (unescaped : plain : accumulated)
    Just (other, _) ->
      Left ("broken string parser invariant at " <> Text.singleton other)

-- | Parse one escape sequence after the backslash.
parseEscape :: Text -> Either Text (Text, Text)
parseEscape input =
  case Text.uncons input of
    Nothing -> Left "unterminated escape sequence"
    Just (c, rest) -> if
      | c == '"'  -> Right ("\"", rest)
      | c == '\\' -> Right ("\\", rest)
      | c == '/'  -> Right ("/", rest)
      | c == 'b'  -> Right ("\b", rest)
      | c == 'f'  -> Right ("\f", rest)
      | c == 'n'  -> Right ("\n", rest)
      | c == 'r'  -> Right ("\r", rest)
      | c == 't'  -> Right ("\t", rest)
      | c == 'u'  -> parseUnicodeEscape rest
      | otherwise -> Left ("invalid escape \\" <> Text.singleton c)

-- | Parse the four hex digits of a \\uXXXX escape, combining UTF-16
-- surrogate pairs. A lone surrogate becomes U+FFFD.
parseUnicodeEscape :: Text -> Either Text (Text, Text)
parseUnicodeEscape input = do
  (high, afterHigh) <- parseHex4 input
  if high >= 0xD800 && high <= 0xDBFF
    then case Text.stripPrefix "\\u" afterHigh of
      Nothing -> Right ("\xFFFD", afterHigh)
      Just afterSecondEscape -> do
        (low, afterLow) <- parseHex4 afterSecondEscape
        if low >= 0xDC00 && low <= 0xDFFF
          then
            let combined = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
            in Right (Text.singleton (chr combined), afterLow)
          else Right ("\xFFFD", afterLow)
    else if high >= 0xDC00 && high <= 0xDFFF
      then Right ("\xFFFD", afterHigh)
      else Right (Text.singleton (chr high), afterHigh)

-- | Read exactly four hex digits.
parseHex4 :: Text -> Either Text (Int, Text)
parseHex4 input =
  let (digits, rest) = Text.splitAt 4 input
  in if Text.length digits == 4 && Text.all isHexDigit digits
    then Right (Text.foldl' (\total c -> total * 16 + hexDigitValue c) 0 digits, rest)
    else Left ("invalid \\u escape: " <> digits)

-- | Value of a single hex digit character.
hexDigitValue :: Char -> Int
hexDigitValue c = if
  | c >= '0' && c <= '9' -> ord c - ord '0'
  | c >= 'a' && c <= 'f' -> ord c - ord 'a' + 10
  | c >= 'A' && c <= 'F' -> ord c - ord 'A' + 10
  | otherwise -> 0

-- | Render a JSON document. Integral numbers print without a decimal
-- point ("advPrd":2000, not 2000.0): the beacon firmware and KKM's
-- own serializer use plain integers. Note that KKM's Android library
-- strips every backslash from generated JSON before sending
-- (KBCfgHandler.objectsToJsonString), so messages sent to a beacon
-- must never rely on escape sequences; our generated messages contain
-- only plain ASCII keys and numbers.
renderJson :: JsonValue -> Text
renderJson = \case
  JsonNull -> "null"
  JsonBool True -> "true"
  JsonBool False -> "false"
  JsonNumber number -> renderNumber number
  JsonString string -> renderString string
  JsonArray items ->
    "[" <> Text.intercalate "," (map renderJson items) <> "]"
  JsonObject members ->
    "{" <> Text.intercalate "," (map renderMember members) <> "}"

-- | Render one object member.
renderMember :: (Text, JsonValue) -> Text
renderMember (key, value) = renderString key <> ":" <> renderJson value

-- | Render a number, preferring the integer form. Integrality is
-- detected by round-tripping (round, convert back, compare): exact
-- integers survive unchanged, anything with a fraction does not. The
-- 1.0e15 cap keeps the integer rendering well inside Double's 2^53
-- exact range.
renderNumber :: Double -> Text
renderNumber number =
  let rounded = round number :: Integer
      integral = case Integer.toDouble rounded of
        Right back -> back == number
        Left _ -> False
  in if integral && abs number < 1.0e15
    then Text.pack (show rounded)
    else Text.pack (show number)

-- | Render a string with the escapes JSON requires.
renderString :: Text -> Text
renderString string = "\"" <> Text.concatMap escapeStringChar string <> "\""

-- | Escape one character inside a rendered string.
escapeStringChar :: Char -> Text
escapeStringChar c = if
  | c == '"' -> "\\\""
  | c == '\\' -> "\\\\"
  | c == '\n' -> "\\n"
  | c == '\r' -> "\\r"
  | c == '\t' -> "\\t"
  | ord c < 0x20 ->
      let hex = Text.pack (padHex (ord c))
      in "\\u" <> hex
  | otherwise -> Text.singleton c

-- | Four-digit lowercase hex for control-character escapes.
padHex :: Int -> String
padHex value =
  let raw = hexString value
  in replicate (4 - length raw) '0' ++ raw

-- | Lowercase hex digits of a non-negative Int.
hexString :: Int -> String
hexString value =
  if value < 16
    then [hexDigitChar value]
    else hexString (value `div` 16) ++ [hexDigitChar (value `mod` 16)]

-- | The lowercase hex digit for a value 0..15.
hexDigitChar :: Int -> Char
hexDigitChar value =
  if value < 10
    then chr (ord '0' + value)
    else chr (ord 'a' + value - 10)

-- | Look up a field of a JSON object. 'Nothing' when the value is not
-- an object or the field is absent.
lookupField :: Text -> JsonValue -> Maybe JsonValue
lookupField key = \case
  JsonObject members -> lookup key members
  JsonArray _ -> Nothing
  JsonString _ -> Nothing
  JsonNumber _ -> Nothing
  JsonBool _ -> Nothing
  JsonNull -> Nothing

-- | Extract an integral number. 'Nothing' for non-numbers and
-- non-integral values.
jsonInt :: JsonValue -> Maybe Int
jsonInt = \case
  JsonNumber number ->
    let rounded = round number :: Int
    in case Int.toDouble rounded of
      Right back -> if back == number then Just rounded else Nothing
      Left _ -> Nothing
  JsonObject _ -> Nothing
  JsonArray _ -> Nothing
  JsonString _ -> Nothing
  JsonBool _ -> Nothing
  JsonNull -> Nothing

-- | A JSON number holding an Int. Values beyond Double's exact
-- integer range (over 2^53, far above anything in this protocol)
-- cannot be represented faithfully and crash loudly rather than
-- silently losing precision.
jsonNumberFromInt :: Int -> JsonValue
jsonNumberFromInt value =
  case Int.toDouble value of
    Right number -> JsonNumber number
    Left _ -> error ("jsonNumberFromInt: " <> show value <> " exceeds Double precision")

-- | Extract a string.
jsonText :: JsonValue -> Maybe Text
jsonText = \case
  JsonString string -> Just string
  JsonObject _ -> Nothing
  JsonArray _ -> Nothing
  JsonNumber _ -> Nothing
  JsonBool _ -> Nothing
  JsonNull -> Nothing

-- | Extract the items of an array.
jsonArrayItems :: JsonValue -> Maybe [JsonValue]
jsonArrayItems = \case
  JsonArray items -> Just items
  JsonObject _ -> Nothing
  JsonString _ -> Nothing
  JsonNumber _ -> Nothing
  JsonBool _ -> Nothing
  JsonNull -> Nothing
