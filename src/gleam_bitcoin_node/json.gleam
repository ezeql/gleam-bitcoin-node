import gleam/int
import gleam/list
import gleam/string

pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  String(String)
  Array(List(Value))
  Object(List(#(String, Value)))
}

pub fn decode(text: String) -> Result(Value, Nil) {
  case parse_value(text) {
    Error(_) -> Error(Nil)
    Ok(#(value, rest)) ->
      case skip(rest) {
        "" -> Ok(value)
        _ -> Error(Nil)
      }
  }
}

pub fn encode(value: Value) -> String {
  case value {
    Null -> "null"
    Bool(True) -> "true"
    Bool(False) -> "false"
    Int(n) -> int.to_string(n)
    String(text) -> "\"" <> escape(text) <> "\""
    Array(items) -> "[" <> join(list.map(items, encode), ", ") <> "]"
    Object(pairs) ->
      "{"
      <> join(
        list.map(pairs, fn(pair) {
          let #(key, item) = pair
          "\"" <> escape(key) <> "\": " <> encode(item)
        }),
        ", ",
      )
      <> "}"
  }
}

pub fn field(value: Value, key: String) -> Result(Value, Nil) {
  case value {
    Object(pairs) -> list.key_find(pairs, key)
    _ -> Error(Nil)
  }
}

fn join(parts: List(String), sep: String) -> String {
  case parts {
    [] -> ""
    [one] -> one
    [one, ..rest] -> one <> sep <> join(rest, sep)
  }
}

fn escape(text: String) -> String {
  string.replace(string.replace(text, "\\", "\\\\"), "\"", "\\\"")
}

fn parse_value(text: String) -> Result(#(Value, String), Nil) {
  let text = skip(text)
  case string.pop_grapheme(text) {
    Error(_) -> Error(Nil)
    Ok(#("{", rest)) -> parse_object(skip(rest), [])
    Ok(#("[", rest)) -> parse_array(skip(rest), [])
    Ok(#("\"", rest)) ->
      case parse_string(rest, "") {
        Error(_) -> Error(Nil)
        Ok(#(text, rest)) -> Ok(#(String(text), rest))
      }
    Ok(#("t", _)) -> keyword(text, "true", Bool(True))
    Ok(#("f", _)) -> keyword(text, "false", Bool(False))
    Ok(#("n", _)) -> keyword(text, "null", Null)
    Ok(#("-", rest)) ->
      case digits(rest, 0, False) {
        Error(_) -> Error(Nil)
        Ok(#(n, rest)) -> Ok(#(Int(-n), rest))
      }
    Ok(#(char, rest)) ->
      case digit(char) {
        Error(_) -> Error(Nil)
        Ok(n) ->
          case digits(rest, n, True) {
            Error(_) -> Error(Nil)
            Ok(#(n, rest)) -> Ok(#(Int(n), rest))
          }
      }
  }
}

fn keyword(
  text: String,
  word: String,
  value: Value,
) -> Result(#(Value, String), Nil) {
  case string.starts_with(text, word) {
    False -> Error(Nil)
    True -> Ok(#(value, string.drop_start(text, string.length(word))))
  }
}

fn parse_object(
  text: String,
  acc: List(#(String, Value)),
) -> Result(#(Value, String), Nil) {
  let text = skip(text)
  case string.pop_grapheme(text) {
    Ok(#("}", rest)) -> Ok(#(Object(list.reverse(acc)), rest))
    Ok(#(",", rest)) -> parse_object(skip(rest), acc)
    Ok(#("\"", rest)) ->
      case parse_string(rest, "") {
        Error(_) -> Error(Nil)
        Ok(#(key, rest)) ->
          case string.pop_grapheme(skip(rest)) {
            Ok(#(":", rest)) ->
              case parse_value(rest) {
                Error(_) -> Error(Nil)
                Ok(#(value, rest)) -> parse_object(rest, [#(key, value), ..acc])
              }
            _ -> Error(Nil)
          }
      }
    _ -> Error(Nil)
  }
}

fn parse_array(
  text: String,
  acc: List(Value),
) -> Result(#(Value, String), Nil) {
  let text = skip(text)
  case string.pop_grapheme(text) {
    Ok(#("]", rest)) -> Ok(#(Array(list.reverse(acc)), rest))
    Ok(#(",", rest)) -> parse_array(skip(rest), acc)
    Ok(_) ->
      case parse_value(text) {
        Error(_) -> Error(Nil)
        Ok(#(value, rest)) -> parse_array(rest, [value, ..acc])
      }
    Error(_) -> Error(Nil)
  }
}

fn parse_string(text: String, acc: String) -> Result(#(String, String), Nil) {
  case string.pop_grapheme(text) {
    Error(_) -> Error(Nil)
    Ok(#("\"", rest)) -> Ok(#(acc, rest))
    Ok(#("\\", rest)) ->
      case string.pop_grapheme(rest) {
        Ok(#("\"", rest)) -> parse_string(rest, acc <> "\"")
        Ok(#("\\", rest)) -> parse_string(rest, acc <> "\\")
        Ok(#("/", rest)) -> parse_string(rest, acc <> "/")
        Ok(#("n", rest)) -> parse_string(rest, acc <> "\n")
        Ok(#("r", rest)) -> parse_string(rest, acc <> "\r")
        Ok(#("t", rest)) -> parse_string(rest, acc <> "\t")
        _ -> Error(Nil)
      }
    Ok(#(char, rest)) -> parse_string(rest, acc <> char)
  }
}

fn digits(
  text: String,
  acc: Int,
  started: Bool,
) -> Result(#(Int, String), Nil) {
  case string.pop_grapheme(text) {
    Ok(#(char, rest)) ->
      case digit(char) {
        Ok(n) -> digits(rest, acc * 10 + n, True)
        Error(_) ->
          case started {
            False -> Error(Nil)
            True ->
              case char {
                "." -> skip_frac(rest, acc)
                _ -> Ok(#(acc, text))
              }
          }
      }
    Error(_) ->
      case started {
        True -> Ok(#(acc, text))
        False -> Error(Nil)
      }
  }
}

fn skip_frac(text: String, acc: Int) -> Result(#(Int, String), Nil) {
  case string.pop_grapheme(text) {
    Ok(#(char, rest)) ->
      case digit(char) {
        Ok(_) -> skip_frac(rest, acc)
        Error(_) -> Ok(#(acc, text))
      }
    Error(_) -> Ok(#(acc, ""))
  }
}

fn digit(char: String) -> Result(Int, Nil) {
  case char {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    _ -> Error(Nil)
  }
}

fn skip(text: String) -> String {
  case string.pop_grapheme(text) {
    Ok(#(" ", rest)) -> skip(rest)
    Ok(#("\n", rest)) -> skip(rest)
    Ok(#("\r", rest)) -> skip(rest)
    Ok(#("\t", rest)) -> skip(rest)
    _ -> text
  }
}
