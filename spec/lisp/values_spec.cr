require "../spec_helper"

describe LISP::LispInt do
  it "displays as its integer value" do
    LISP::LispInt.new(42_i64).display_string.should eq("42")
  end

  it "writes the same as it displays" do
    LISP::LispInt.new(-7_i64).write_string.should eq("-7")
  end
end

describe LISP::LispFloat do
  it "displays whole floats with a trailing .0" do
    LISP::LispFloat.new(3.0).display_string.should eq("3.0")
  end

  it "displays negative whole floats with a trailing .0" do
    LISP::LispFloat.new(-2.0).display_string.should eq("-2.0")
  end

  it "displays fractional floats normally" do
    LISP::LispFloat.new(3.5).display_string.should eq("3.5")
  end

  it "displays very large whole floats without the .0 shortcut" do
    LISP::LispFloat.new(1e16).display_string.should eq("1.0e+16")
  end
end

describe LISP::LispStr do
  it "displays the raw string" do
    LISP::LispStr.new("hello\nworld").display_string.should eq("hello\nworld")
  end

  it "writes an escaped, quoted string" do
    LISP::LispStr.new(%(a"b\\c\nd\te\rf\0g)).write_string.should eq(%("a\\"b\\\\c\\nd\\te\\rf\\0g"))
  end

  it "writes plain strings with surrounding quotes" do
    LISP::LispStr.new("plain").write_string.should eq(%("plain"))
  end
end

describe LISP::LispSym do
  it "interns symbols with the same name to the same object" do
    LISP::LispSym.of("foo").should be(LISP::LispSym.of("foo"))
  end

  it "gives distinct names distinct objects" do
    LISP::LispSym.of("foo").should_not be(LISP::LispSym.of("bar"))
  end

  it "displays its name" do
    LISP::LispSym.of("my-sym").display_string.should eq("my-sym")
  end
end

describe LISP::LispBool do
  it "interns true via .of" do
    LISP::LispBool.of(true).should be(LISP::TRUE)
  end

  it "interns false via .of" do
    LISP::LispBool.of(false).should be(LISP::FALSE)
  end

  it "displays true as #t" do
    LISP::TRUE.display_string.should eq("#t")
  end

  it "displays false as #f" do
    LISP::FALSE.display_string.should eq("#f")
  end
end

describe LISP::LispNil do
  it "is a singleton" do
    LISP::LispNil.new.should_not be(LISP::NIL)
    LISP::NIL.should be(LISP::NIL)
  end

  it "displays as ()" do
    LISP::NIL.display_string.should eq("()")
  end
end

describe LISP::LispChar do
  it "displays the raw character" do
    LISP::LispChar.new('x').display_string.should eq("x")
  end

  it "writes named char: space" do
    LISP::LispChar.new(' ').write_string.should eq("#\\space")
  end

  it "writes named char: newline" do
    LISP::LispChar.new('\n').write_string.should eq("#\\newline")
  end

  it "writes named char: tab" do
    LISP::LispChar.new('\t').write_string.should eq("#\\tab")
  end

  it "writes named char: return" do
    LISP::LispChar.new('\r').write_string.should eq("#\\return")
  end

  it "writes named char: nul" do
    LISP::LispChar.new('\0').write_string.should eq("#\\nul")
  end

  it "writes a generic char literally" do
    LISP::LispChar.new('x').write_string.should eq("#\\x")
  end
end

describe LISP::Cons do
  it "displays a proper list" do
    lst = LISP.a_to_list([LISP::LispInt.new(1_i64), LISP::LispInt.new(2_i64), LISP::LispInt.new(3_i64)] of LISP::LispValue)
    lst.display_string.should eq("(1 2 3)")
  end

  it "displays a dotted pair" do
    LISP::Cons.new(LISP::LispInt.new(1_i64), LISP::LispInt.new(2_i64)).display_string.should eq("(1 . 2)")
  end

  it "displays nested lists" do
    inner = LISP.a_to_list([LISP::LispInt.new(2_i64), LISP::LispInt.new(3_i64)] of LISP::LispValue)
    outer = LISP.a_to_list([LISP::LispInt.new(1_i64), inner] of LISP::LispValue)
    outer.display_string.should eq("(1 (2 3))")
  end

  it "writes strings inside lists escaped" do
    lst = LISP.a_to_list([LISP::LispStr.new("a\nb")] of LISP::LispValue)
    lst.write_string.should eq(%(("a\\nb")))
  end

  it "displays strings inside lists unescaped" do
    lst = LISP.a_to_list([LISP::LispStr.new("a\nb")] of LISP::LispValue)
    lst.display_string.should eq("(a\nb)")
  end
end

describe LISP::Lambda do
  it "stores params, rest, body, env and name" do
    env = LISP::Env.new
    body = [LISP::LispInt.new(1_i64)] of LISP::LispValue
    lam = LISP::Lambda.new(["x"], "rest", body, env, "myfn")
    lam.params.should eq(["x"])
    lam.rest.should eq("rest")
    lam.body.should eq(body)
    lam.env.should be(env)
    lam.name.should eq("myfn")
  end

  it "defaults name to lambda" do
    LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new).name.should eq("lambda")
  end

  it "name is mutable" do
    lam = LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new)
    lam.name = "renamed"
    lam.name.should eq("renamed")
  end

  it "displays as #<procedure:name>" do
    lam = LISP::Lambda.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new, "adder")
    lam.display_string.should eq("#<procedure:adder>")
  end
end

describe LISP::Macro do
  it "stores params, rest, body, env and name" do
    env = LISP::Env.new
    body = [LISP::LispInt.new(1_i64)] of LISP::LispValue
    mac = LISP::Macro.new(["x"], "rest", body, env, "mymacro")
    mac.params.should eq(["x"])
    mac.rest.should eq("rest")
    mac.body.should eq(body)
    mac.env.should be(env)
    mac.name.should eq("mymacro")
  end

  it "defaults name to macro" do
    LISP::Macro.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new).name.should eq("macro")
  end

  it "name is mutable" do
    mac = LISP::Macro.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new)
    mac.name = "renamed"
    mac.name.should eq("renamed")
  end

  it "displays as #<macro:name>" do
    mac = LISP::Macro.new([] of String, nil, [] of LISP::LispValue, LISP::Env.new, "swap!")
    mac.display_string.should eq("#<macro:swap!>")
  end
end

describe LISP::Builtin do
  it "stores name and arity" do
    b = LISP::Builtin.new("plus", 0, -1) { |args| LISP::LispInt.new(args.size.to_i64) }
    b.name.should eq("plus")
    b.min_arity.should eq(0)
    b.max_arity.should eq(-1)
  end

  it "invokes the given block via fn" do
    b = LISP::Builtin.new("plus", 0, -1) { |args| LISP::LispInt.new(args.size.to_i64) }
    result = b.fn.call([LISP::NIL, LISP::NIL] of LISP::LispValue)
    result.as(LISP::LispInt).value.should eq(2_i64)
  end

  it "displays as #<builtin:name>" do
    b = LISP::Builtin.new("plus", 0, -1) { |_| LISP::NIL.as(LISP::LispValue) }
    b.display_string.should eq("#<builtin:plus>")
  end
end

describe LISP::LispVector do
  it "displays elements space-separated inside #(...)" do
    v = LISP::LispVector.new([LISP::LispInt.new(1_i64), LISP::LispInt.new(2_i64)] of LISP::LispValue)
    v.display_string.should eq("#(1 2)")
  end

  it "writes strings quoted inside the vector" do
    v = LISP::LispVector.new([LISP::LispStr.new("a")] of LISP::LispValue)
    v.write_string.should eq(%(#("a")))
    v.display_string.should eq("#(a)")
  end

  it "displays an empty vector" do
    LISP::LispVector.new.display_string.should eq("#()")
  end
end

describe LISP::LispBlob do
  it "stores the given bytes" do
    bytes = Bytes[1, 2, 3]
    LISP::LispBlob.new(bytes).value.should eq(bytes)
  end

  it "displays as #<blob:N bytes>" do
    LISP::LispBlob.new(Bytes[1, 2, 3]).display_string.should eq("#<blob:3 bytes>")
  end

  it "displays an empty blob" do
    LISP::LispBlob.new(Bytes.empty).display_string.should eq("#<blob:0 bytes>")
  end
end
