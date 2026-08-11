require "../../spec_helper"

describe Creme::SchemeInt do
  it "displays as its integer value" do
    Creme::SchemeInt.new(42_i64).display_string.should eq("42")
  end

  it "writes the same as it displays" do
    Creme::SchemeInt.new(-7_i64).write_string.should eq("-7")
  end
end

describe Creme::SchemeFloat do
  it "displays whole floats with a trailing .0" do
    Creme::SchemeFloat.new(3.0).display_string.should eq("3.0")
  end

  it "displays negative whole floats with a trailing .0" do
    Creme::SchemeFloat.new(-2.0).display_string.should eq("-2.0")
  end

  it "displays fractional floats normally" do
    Creme::SchemeFloat.new(3.5).display_string.should eq("3.5")
  end

  it "displays very large whole floats without the .0 shortcut" do
    Creme::SchemeFloat.new(1e16).display_string.should eq("1.0e+16")
  end
end

describe Creme::SchemeStr do
  it "displays the raw string" do
    Creme::SchemeStr.new("hello\nworld").display_string.should eq("hello\nworld")
  end

  it "writes an escaped, quoted string" do
    Creme::SchemeStr.new(%(a"b\\c\nd\te\rf\0g)).write_string.should eq(%("a\\"b\\\\c\\nd\\te\\rf\\0g"))
  end

  it "writes plain strings with surrounding quotes" do
    Creme::SchemeStr.new("plain").write_string.should eq(%("plain"))
  end
end

describe Creme::SchemeSym do
  it "interns symbols with the same name to the same object" do
    Creme::SchemeSym.of("foo").should be(Creme::SchemeSym.of("foo"))
  end

  it "gives distinct names distinct objects" do
    Creme::SchemeSym.of("foo").should_not be(Creme::SchemeSym.of("bar"))
  end

  it "displays its name" do
    Creme::SchemeSym.of("my-sym").display_string.should eq("my-sym")
  end
end

describe Creme::SchemeBool do
  it "interns true via .of" do
    Creme::SchemeBool.of(true).should be(Creme::TRUE)
  end

  it "interns false via .of" do
    Creme::SchemeBool.of(false).should be(Creme::FALSE)
  end

  it "displays true as #t" do
    Creme::TRUE.display_string.should eq("#t")
  end

  it "displays false as #f" do
    Creme::FALSE.display_string.should eq("#f")
  end
end

describe Creme::SchemeNil do
  it "is a singleton" do
    Creme::SchemeNil.new.should_not be(Creme::NIL)
    Creme::NIL.should be(Creme::NIL)
  end

  it "displays as ()" do
    Creme::NIL.display_string.should eq("()")
  end
end

describe Creme::SchemeChar do
  it "displays the raw character" do
    Creme::SchemeChar.new('x').display_string.should eq("x")
  end

  it "writes named char: space" do
    Creme::SchemeChar.new(' ').write_string.should eq("#\\space")
  end

  it "writes named char: newline" do
    Creme::SchemeChar.new('\n').write_string.should eq("#\\newline")
  end

  it "writes named char: tab" do
    Creme::SchemeChar.new('\t').write_string.should eq("#\\tab")
  end

  it "writes named char: return" do
    Creme::SchemeChar.new('\r').write_string.should eq("#\\return")
  end

  it "writes named char: null" do
    Creme::SchemeChar.new('\0').write_string.should eq("#\\null")
  end

  it "writes a generic char literally" do
    Creme::SchemeChar.new('x').write_string.should eq("#\\x")
  end
end

describe Creme::Cons do
  it "displays a proper list" do
    lst = Creme.a_to_list([Creme::SchemeInt.new(1_i64), Creme::SchemeInt.new(2_i64), Creme::SchemeInt.new(3_i64)] of Creme::SchemeValue)
    lst.display_string.should eq("(1 2 3)")
  end

  it "displays a dotted pair" do
    Creme::Cons.new(Creme::SchemeInt.new(1_i64), Creme::SchemeInt.new(2_i64)).display_string.should eq("(1 . 2)")
  end

  it "displays nested lists" do
    inner = Creme.a_to_list([Creme::SchemeInt.new(2_i64), Creme::SchemeInt.new(3_i64)] of Creme::SchemeValue)
    outer = Creme.a_to_list([Creme::SchemeInt.new(1_i64), inner] of Creme::SchemeValue)
    outer.display_string.should eq("(1 (2 3))")
  end

  it "writes strings inside lists escaped" do
    lst = Creme.a_to_list([Creme::SchemeStr.new("a\nb")] of Creme::SchemeValue)
    lst.write_string.should eq(%(("a\\nb")))
  end

  it "displays strings inside lists unescaped" do
    lst = Creme.a_to_list([Creme::SchemeStr.new("a\nb")] of Creme::SchemeValue)
    lst.display_string.should eq("(a\nb)")
  end
end

describe Creme::Macro do
  it "stores params, rest, body, env and name" do
    env = Creme::Env.new
    body = [Creme::SchemeInt.new(1_i64)] of Creme::SchemeValue
    mac = Creme::Macro.new(["x"], "rest", body, env, "mymacro")
    mac.params.should eq(["x"])
    mac.rest.should eq("rest")
    mac.body.should eq(body)
    mac.env.should be(env)
    mac.name.should eq("mymacro")
  end

  it "defaults name to macro" do
    Creme::Macro.new([] of String, nil, [] of Creme::SchemeValue, Creme::Env.new).name.should eq("macro")
  end

  it "name is mutable" do
    mac = Creme::Macro.new([] of String, nil, [] of Creme::SchemeValue, Creme::Env.new)
    mac.name = "renamed"
    mac.name.should eq("renamed")
  end

  it "displays as #<macro:name>" do
    mac = Creme::Macro.new([] of String, nil, [] of Creme::SchemeValue, Creme::Env.new, "swap!")
    mac.display_string.should eq("#<macro:swap!>")
  end
end

describe Creme::Builtin do
  it "stores name and arity" do
    b = Creme::Builtin.new("plus", 0, -1) { |args| Creme::SchemeInt.new(args.size.to_i64) }
    b.name.should eq("plus")
    b.min_arity.should eq(0)
    b.max_arity.should eq(-1)
  end

  it "invokes the given block via fn" do
    b = Creme::Builtin.new("plus", 0, -1) { |args| Creme::SchemeInt.new(args.size.to_i64) }
    result = b.fn.call([Creme::NIL, Creme::NIL] of Creme::SchemeValue)
    result.as(Creme::SchemeInt).value.should eq(2_i64)
  end

  it "displays as #<builtin:name>" do
    b = Creme::Builtin.new("plus", 0, -1) { |_| Creme::NIL.as(Creme::SchemeValue) }
    b.display_string.should eq("#<builtin:plus>")
  end
end

describe Creme::SchemeVector do
  it "displays elements space-separated inside #(...)" do
    v = Creme::SchemeVector.new([Creme::SchemeInt.new(1_i64), Creme::SchemeInt.new(2_i64)] of Creme::SchemeValue)
    v.display_string.should eq("#(1 2)")
  end

  it "writes strings quoted inside the vector" do
    v = Creme::SchemeVector.new([Creme::SchemeStr.new("a")] of Creme::SchemeValue)
    v.write_string.should eq(%(#("a")))
    v.display_string.should eq("#(a)")
  end

  it "displays an empty vector" do
    Creme::SchemeVector.new.display_string.should eq("#()")
  end
end

describe Creme::SchemeBlob do
  it "stores the given bytes" do
    bytes = Bytes[1, 2, 3]
    Creme::SchemeBlob.new(bytes).value.should eq(bytes)
  end

  it "displays as #<blob:N bytes>" do
    Creme::SchemeBlob.new(Bytes[1, 2, 3]).display_string.should eq("#<blob:3 bytes>")
  end

  it "displays an empty blob" do
    Creme::SchemeBlob.new(Bytes.empty).display_string.should eq("#<blob:0 bytes>")
  end

  it "write_string shows #u8(...) contents, per R7RS bytevector write syntax" do
    Creme::SchemeBlob.new(Bytes[1, 2, 255]).write_string.should eq("#u8(1 2 255)")
  end

  it "write_string shows #u8() for an empty bytevector" do
    Creme::SchemeBlob.new(Bytes.empty).write_string.should eq("#u8()")
  end
end

describe Creme::SchemeRecordType do
  it "displays as #<record-type:name>" do
    Creme::SchemeRecordType.new("point", ["x", "y"]).display_string.should eq("#<record-type:point>")
  end
end

describe Creme::SchemeRecord do
  it "displays with its type name and field=value pairs" do
    t = Creme::SchemeRecordType.new("point", ["x", "y"])
    r = Creme::SchemeRecord.new(t, [Creme::SchemeInt.new(1_i64), Creme::SchemeInt.new(2_i64)] of Creme::SchemeValue)
    r.display_string.should eq("#<point x=1 y=2>")
  end

  it "displays a record with no fields" do
    t = Creme::SchemeRecordType.new("marker", [] of String)
    r = Creme::SchemeRecord.new(t, [] of Creme::SchemeValue)
    r.display_string.should eq("#<marker>")
  end
end

describe Creme::SchemeSyntaxRules do
  it "displays as #<syntax-rules:name>" do
    Creme::SchemeSyntaxRules.new("my-if", [] of String, [] of {Creme::SchemeValue, Creme::SchemeValue}, Creme::Env.new).display_string.should eq("#<syntax-rules:my-if>")
  end
end

describe Creme::SchemeParameter do
  it "displays as #<parameter>" do
    Creme::SchemeParameter.new(Creme::SchemeInt.new(1_i64)).display_string.should eq("#<parameter>")
  end
end

describe Creme::SchemeValues do
  it "displays its items" do
    v = Creme::SchemeValues.new([Creme::SchemeInt.new(1_i64), Creme::SchemeInt.new(2_i64)] of Creme::SchemeValue)
    v.display_string.should eq("#<values 1 2>")
  end

  it "displays with no items" do
    Creme::SchemeValues.new([] of Creme::SchemeValue).display_string.should eq("#<values>")
  end
end

describe Creme::SchemeContinuation do
  it "displays as #<continuation>" do
    Creme::SchemeContinuation.new(1_i64).display_string.should eq("#<continuation>")
  end
end

describe Creme::SchemeHashTable do
  it "displays with its entry count" do
    Creme::SchemeHashTable.new.display_string.should eq("#<hash-table 0 entries>")
    entries = [{Creme::SchemeSym.of("a").as(Creme::SchemeValue), Creme::SchemeInt.new(1_i64).as(Creme::SchemeValue)}]
    h = Creme::SchemeHashTable.new(entries)
    h.display_string.should eq("#<hash-table 1 entries>")
  end

  it "finds a key by equal?, not identity" do
    key1 = Creme.a_to_list([Creme::SchemeInt.new(1_i64)] of Creme::SchemeValue)
    key2 = Creme.a_to_list([Creme::SchemeInt.new(1_i64)] of Creme::SchemeValue)
    entries = [{key1.as(Creme::SchemeValue), Creme::SchemeInt.new(99_i64).as(Creme::SchemeValue)}]
    h = Creme::SchemeHashTable.new(entries)
    h.contains?(key2).should be_true
    h.get?(key2).should eq(Creme::SchemeInt.new(99_i64))
  end

  it "reports absent keys as not found" do
    h = Creme::SchemeHashTable.new
    h.contains?(Creme::SchemeSym.of("z")).should be_false
    h.get?(Creme::SchemeSym.of("z")).should be_nil
  end
end

describe Creme::SchemePromise do
  it "displays as unforced before being forced" do
    thunk = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    Creme::SchemePromise.new(thunk).display_string.should eq("#<promise>")
  end

  it "displays as forced once forced" do
    thunk = Creme::Builtin.new("dummy", 0, 0) { Creme::NIL.as(Creme::SchemeValue) }
    p = Creme::SchemePromise.new(thunk)
    p.forced = true
    p.display_string.should eq("#<promise forced>")
  end
end
