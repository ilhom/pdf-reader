require 'parslet'
require 'rspec'

class PdfParser < Parslet::Parser

  rule(:space)      { (str("\x00") | str("\x09") | str("\x0A") | str("\x0C") | str("\x0D") | str("\x20")).repeat(1) }
  rule(:space?)     { space.maybe }

  # match any regular byte, basically anything that isn't whitespace or a
  # delimiter
  rule(:regular)   { match('[^\(\)<>\[\]{}/%\x00\x09\x0A\x0C\x0D\x20]')}

  rule(:doc) { ( string_literal | string_hex | array | dict | name | boolean | null | keyword | indirect | float | integer | space ).repeat }

  rule(:string_literal) {
    str("(") >> (
      (str('\\') >> any) |
      (str(')').absent? >> any)
    ).repeat.as(:string_literal) >> str(")")
  }

  rule(:string_hex)     { str("<") >> (match('[A-Fa-f0-9]') | space).repeat(1).as(:string_hex) >> str(">") }

  rule(:array)          { str("[") >> doc.as(:array) >> str("]") }

  rule(:dict)           { str("<<") >> doc.as(:dict) >> str(">>") }

  rule(:name)           { str('/') >> regular.repeat(1).as(:name) }

  rule(:float)          { (match('[\+\-]').maybe >> match('[0-9]').repeat(1) >> str('.') >> match('[0-9]').repeat(1) ).as(:float) }

  rule(:integer)        { (match('[\+\-]').maybe >> match('[0-9]').repeat(1)).as(:integer) }

  rule(:indirect)       { (match('[0-9]').repeat(1) >> space >> match('[0-9]').repeat(1) >> space >> str("R")).as(:indirect) }

  rule(:boolean)        { (str("true") | str("false")).as(:boolean)}

  rule(:null)           { str('null').as(:null) }

  rule(:keyword)        { (str('obj') | str('endobj') | str('stream') | str('endstream')).as(:keyword)}

  root(:doc)
end

class PdfTransform < Parslet::Transform
  rule(:string_literal => simple(:value)) { value }
  rule(:string_literal => subtree(:value)) {
    if value.is_a?(String)
      value
    elsif value.is_a?(Array) && value.empty?
      ""
    else
      PdfTransform.new.apply(value)
    end
  }

  rule(:string_hex => simple(:value)) {
    value << "0" unless value.size % 2 == 0
    value.gsub(/[^A-F0-9]/i,"").scan(/../).map { |i| i.hex.chr }.join
  }

  rule(:name => simple(:value)) {
    value.scan(/#([A-Fa-f0-9]{2})/).each do |find|
      replace = find[0].hex.chr
      value.gsub!("#"+find[0], replace)
    end
    value.to_sym
  }

  rule(:float => simple(:value)) { value.to_f }

  rule(:integer => simple(:value)) { value.to_i }

  rule(:boolean => simple(:value)) { value == "true" }

  rule(:null => simple(:value)) { nil }

  rule(:array => subtree(:contents)) { PdfTransform.new.apply(contents) }

  rule(:dict => subtree(:contents)) {
    Hash[*PdfTransform.new.apply(contents)]
  }

  rule(:indirect => simple(:value)) { value }

  rule(:keyword => simple(:value)) { value}
end

class Parser

  def initialize (str, objects=nil)
    ast     = PdfParser.new.parse(str)
    @tokens  = PdfTransform.new.apply(ast)
    @objects = objects
  end

  def parse_token
    @tokens.shift
  end
end

describe PdfTransform do
  let(:transform) { PdfTransform.new }

  it "transforms a literal string" do
    str = [{ :string_literal => "abc"}]
    transform.apply(str).should == %w{ abc }
  end

  it "transforms a an empty literal string" do
    ast = [{ :string_literal => [] }]
    transform.apply(ast).should == [ "" ]
  end

  it "transforms a hex string without captials" do
    str = [{ :string_hex => "00ffab"}]
    transform.apply(str).should == [ "\x00\xff\xab" ]
  end

  it "transforms a hex string with spaces" do
    str = [{ :string_hex => "00ff ab"}]
    transform.apply(str).should == [ "\x00\xff\xab" ]
  end

  it "transforms a hex string with an odd number of characters" do
    str = [{ :string_hex => "00ffa"}]
    transform.apply(str).should == [ "\x00\xff\xa0" ]
  end

  it "transforms a PDF Name to a ruby symbol" do
    str = [{ :name => "James"}]
    transform.apply(str).should == [ :James ]
  end

  it "transforms a PDF Name with encoded bytes to a ruby symbol" do
    str = [{ :name => "James#20Healy"}]
    transform.apply(str).should == [ :"James Healy" ]
  end

  it "transforms a PDF Name with encoded bytes to a ruby symbol" do
    str = [{ :name => "James#23Healy"}]
    transform.apply(str).should == [ :"James#Healy" ]
  end

  it "transforms a PDF Name with encoded bytes to a ruby symbol" do
    str = [{ :name => "Ja#6des"}]
    transform.apply(str).should == [ :"James" ]
  end

  it "transforms a float" do
    str = [{ :float => "1.9"}]
    transform.apply(str).should == [ 1.9 ]
  end

  it "transforms an int" do
    str = [{ :float => "10"}]
    transform.apply(str).should == [ 10 ]
  end

  it "transforms a true boolean" do
    str = [{ :boolean => "true"}]
    transform.apply(str).should == [ true ]
  end

  it "transforms a false boolean" do
    str = [{ :boolean => "false"}]
    transform.apply(str).should == [ false ]
  end

  it "transforms a null" do
    str = [{ :null => "null"}]
    transform.apply(str).should == [ nil ]
  end

  it "transforms an array" do
    ast = [
      { :array => [
        {:integer => "1"},
        {:integer => "2"},
        {:integer => "3"},
        {:integer => "4"}
        ]
      }
    ]
    transform.apply(ast).should == [ [1, 2, 3, 4] ]
  end

  it "transforms a dict" do
    ast = [
      { :dict => [
        {:name => "One"},
        {:integer => "1"},
        {:name => "Two"},
        {:integer => "2"}
        ]
      }
    ]
    transform.apply(ast).should == [ {:One => 1, :Two => 2} ]
  end

  it "transforms an indirect reference" do
    # TODO this should actually transform the reference into a
    #      PDF::Reader::Reference object
    ast = [ {:indirect => "1 0 R"} ]
    transform.apply(ast).should == [ "1 0 R" ]
  end

  it "transforms a PDF keyword" do
    ast = [ {:keyword => "endstream"} ]
    transform.apply(ast).should == [ "endstream" ]
  end
end

describe PdfParser do
  let(:parser) { PdfParser.new }

  it "should parse a literal string" do
    str = "(abc)"
    ast = [{ :string_literal => "abc" }]
    parser.parse(str).should == ast
  end

  it "should parse two literal strings" do
    str    = "(abc) (def)"
    ast = [{ :string_literal => "abc" }, { :string_literal => "def"}]
    parser.parse(str).should == ast
  end

  it "should parse a literal string with capitals" do
    str    = "(ABC)"
    ast = [{ :string_literal => "ABC" }]
    parser.parse(str).should == ast
  end

  it "should parse a literal string with spaces" do
    str    = " (abc) "
    ast = [{ :string_literal => "abc" }]
    parser.parse(str).should == ast
  end

  it "should parse an empty string" do
    str    = "()"
    ast = [{ :string_literal => [] }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing spaces" do
    str    = "(this is a string)"
    ast = [{ :string_literal => "this is a string" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped newline" do
    str    = "(this \\n is a string)"
    ast = [{ :string_literal => "this \\n is a string" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped tab" do
    str    = "(x \\t x)"
    ast = [{ :string_literal => "x \\t x" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped octal" do
    str    = "(x \\101 x)"
    ast = [{ :string_literal => "x \\101 x" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped octal" do
    str    = "(x \\61 x)"
    ast = [{ :string_literal => "x \\61 x" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped digit" do
    str    = "(x \\1 x)"
    ast = [{ :string_literal => "x \\1 x" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped left paren" do
    str    = "(x \\( x)"
    ast = [{ :string_literal => "x \\( x" }]
    parser.parse(str).should == ast
  end

  it "should parse a string containing an escaped right paren" do
    str    = "(x \\) x)"
    ast = [{ :string_literal => "x \\) x" }]
    parser.parse(str).should == ast
  end

  #it "should parse a string containing an balanced nested parens" do
  #  str    = "((x))"
  #  ast = [{ :string_literal => "(x)" }]
  #  parser.parse(str).should == ast
  #end

  it "should parse a hex string without captials" do
    str = "<00ffab>"
    ast = [ { :string_hex => "00ffab" } ]
    parser.parse(str).should == ast
  end

  it "should parse a hex string with captials" do
    str = " <00FFAB> "
    ast = [ { :string_hex => "00FFFB" } ]
    parser.parse(str).should == ast
  end

  it "should parse two hex strings" do
    str = " <00FF> <2030>"
    ast = [ { :string_hex => "00FF"}, {:string_hex => "2030"} ]
    parser.parse(str).should == ast
  end

  it "should parse a hex string with whitespace" do
    str = " <00FF\n2030>"
    ast = [ { :string_hex => "00FF\n2030"} ]
    parser.parse(str).should == ast
  end

  it "should parse an integer" do
    str = "9"
    ast = [ { :integer => "9" } ]
    parser.parse(str).should == ast
  end

  it "should parse a double digit integer" do
    str = "99"
    ast = [ { :integer => "99" } ]
    parser.parse(str).should == ast
  end

  it "should parse a triple digit integer" do
    str = "123"
    ast = [ { :integer => "123" } ]
    parser.parse(str).should == ast
  end

  it "should parse an integer with spaces" do
    str = " 19 "
    ast = [ { :integer => "19" } ]
    parser.parse(str).should == ast
  end

  it "should parse an integer with a + sign" do
    str = "+15"
    ast = [ { :integer => "+15" } ]
    parser.parse(str).should == ast
  end

  it "should parse an integer with a - sign" do
    str = "-34"
    ast = [ { :integer => "-34" } ]
    parser.parse(str).should == ast
  end

  it "should parse a float" do
    str = "1.1"
    ast = [ { :float => "1.1" } ]
    parser.parse(str).should == ast
  end

  it "should parse a float with a + sign" do
    str = "+19.1"
    ast = [ { :float => "+19.1" } ]
    parser.parse(str).should == ast
  end

  it "should parse a float with a - sign" do
    str = "-73.2"
    ast = [ { :float => "-73.2" } ]
    parser.parse(str).should == ast
  end

  it "should parse a float with spaces" do
    str = " 19.9 "
    ast = [ { :float => "19.9" } ]
    parser.parse(str).should == ast
  end

  it "should parse a pdf name" do
    str = "/James"
    ast = [ { :name => "James" } ]
    parser.parse(str).should == ast
  end

  it "should parse a pdf name with spaces" do
    str = " /James "
    ast = [ { :name => "James" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with odd but legal characters" do
    str = "/A;Name_With-Various***Characters?"
    ast = [ { :name => "A;Name_With-Various***Characters?" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name that looks like a float" do
    str = "/1.2"
    ast = [ { :name => "1.2" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with dollar signs" do
    str = "/$$"
    ast = [ { :name => "$$" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with an @ sign" do
    str = "/@pattern"
    ast = [ { :name => "@pattern" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with an decimal point" do
    str = "/.notdef"
    ast = [ { :name => ".notdef" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with an encoded space" do
    str = "/James#20Healy"
    ast = [ { :name => "James#20Healy" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with an encoded #" do
    str = "/James#23Healy"
    ast = [ { :name => "James#23Healy" } ]
    parser.parse(str).should == ast
  end

  it "should parse a name with an encoded m" do
    str = "/Ja#6des"
    ast = [ { :name => "Ja#6des" } ]
    parser.parse(str).should == ast
  end

  it "should parse a true boolean" do
    str = "true"
    ast = [ {:boolean => "true" } ]
    parser.parse(str).should == ast
  end

  it "should parse a false boolean" do
    str = "false"
    ast = [ { :boolean => "false" } ]
    parser.parse(str).should == ast
  end

  it "should parse a null" do
    str = "null"
    ast = [ { :null => "null" } ]
    parser.parse(str).should == ast
  end

  it "should parse an array of ints" do
    str = "[ 1 2 3 4 ]"
    ast = [
      { :array => [
        {:integer => "1"},
        {:integer => "2"},
        {:integer => "3"},
        {:integer => "4"}
        ]
      }
    ]
    parser.parse(str).should == ast
  end

  it "should parse an array of indirect objects" do
    str = "[ 10 0 R 12 0 R ]"
    ast = [
      { :array => [
        {:indirect => "10 0 R"},
        {:indirect => "12 0 R"}
        ]
      }
    ]
    parser.parse(str).should == ast
  end

  it "should parse a simple dictionary" do
    str = "<</One 1 /Two 2>>"
    ast = [
      { :dict => [
        {:name => "One"},
        {:integer => "1"},
        {:name => "Two"},
        {:integer => "2"}
        ]
      }
    ]
    parser.parse(str).should == ast
  end

  it "should parse a dictionary with an embedded hex string" do
    str = "<</X <48656C6C6F> >>"
    ast = [
      { :dict => [
        {:name => "X"},
        {:string_hex => "48656C6C6F"}
        ]
      }
    ]
    parser.parse(str).should == ast
  end

  it "parses an indirect reference" do
    str = "1 0 R"
    ast = [ {:indirect => "1 0 R"} ]
    parser.parse(str).should == ast
  end

  it "parses the 'obj' keyword" do
    str = "obj"
    ast = [ {:keyword => "obj"} ]
    parser.parse(str).should == ast
  end

  it "parses the 'endobj' keyword" do
    str = "endobj"
    ast = [ {:keyword => "endobj"} ]
    parser.parse(str).should == ast
  end

  it "parses the 'stream' keyword" do
    str = "stream"
    ast = [ {:keyword => "stream"} ]
    parser.parse(str).should == ast
  end

  it "parses the 'endstream' keyword" do
    str = "endstream"
    ast = [ {:keyword => "endstream"} ]
    parser.parse(str).should == ast
  end
end