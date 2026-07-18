require "../../spec_helper"

describe Scheme::SchemeInt do
  it "displays as its integer value" do
    Scheme::SchemeInt.new(42_i64).display_string.should eq("42")
  end

  it "writes the same as it displays" do
    Scheme::SchemeInt.new(-7_i64).write_string.should eq("-7")
  end
end

describe Scheme::SchemeFloat do
  it "displays whole floats with a trailing .0" do
    Scheme::SchemeFloat.new(3.0).display_string.should eq("3.0")
  end

  it "displays negative whole floats with a trailing .0" do
    Scheme::SchemeFloat.new(-2.0).display_string.should eq("-2.0")
  end

  it "displays fractional floats normally" do
    Scheme::SchemeFloat.new(3.5).display_string.should eq("3.5")
  end

  it "displays very large whole floats without the .0 shortcut" do
    Scheme::SchemeFloat.new(1e16).display_string.should eq("1.0e+16")
  end
end

describe Scheme::SchemeStr do
  it "displays the raw string" do
    Scheme::SchemeStr.new("hello\nworld").display_string.should eq("hello\nworld")
  end

  it "writes an escaped, quoted string" do
    Scheme::SchemeStr.new(%(a"b\\c\nd\te\rf\0g)).write_string.should eq(%("a\\"b\\\\c\\nd\\te\\rf\\0g"))
  end

  it "writes plain strings with surrounding quotes" do
    Scheme::SchemeStr.new("plain").write_string.should eq(%("plain"))
  end
end

describe Scheme::SchemeSym do
  it "interns symbols with the same name to the same object" do
    Scheme::SchemeSym.of("foo").should be(Scheme::SchemeSym.of("foo"))
  end

  it "gives distinct names distinct objects" do
    Scheme::SchemeSym.of("foo").should_not be(Scheme::SchemeSym.of("bar"))
  end

  it "displays its name" do
    Scheme::SchemeSym.of("my-sym").display_string.should eq("my-sym")
  end
end

describe Scheme::SchemeBool do
  it "interns true via .of" do
    Scheme::SchemeBool.of(true).should be(Scheme::TRUE)
  end

  it "interns false via .of" do
    Scheme::SchemeBool.of(false).should be(Scheme::FALSE)
  end

  it "displays true as #t" do
    Scheme::TRUE.display_string.should eq("#t")
  end

  it "displays false as #f" do
    Scheme::FALSE.display_string.should eq("#f")
  end
end

describe Scheme::SchemeNil do
  it "is a singleton" do
    Scheme::SchemeNil.new.should_not be(Scheme::NIL)
    Scheme::NIL.should be(Scheme::NIL)
  end

  it "displays as ()" do
    Scheme::NIL.display_string.should eq("()")
  end
end

describe Scheme::SchemeChar do
  it "displays the raw character" do
    Scheme::SchemeChar.new('x').display_string.should eq("x")
  end

  it "writes named char: space" do
    Scheme::SchemeChar.new(' ').write_string.should eq("#\\space")
  end

  it "writes named char: newline" do
    Scheme::SchemeChar.new('\n').write_string.should eq("#\\newline")
  end

  it "writes named char: tab" do
    Scheme::SchemeChar.new('\t').write_string.should eq("#\\tab")
  end

  it "writes named char: return" do
    Scheme::SchemeChar.new('\r').write_string.should eq("#\\return")
  end

  it "writes named char: null" do
    Scheme::SchemeChar.new('\0').write_string.should eq("#\\null")
  end

  it "writes a generic char literally" do
    Scheme::SchemeChar.new('x').write_string.should eq("#\\x")
  end
end

describe Scheme::Cons do
  it "displays a proper list" do
    lst = Scheme.a_to_list([Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64), Scheme::SchemeInt.new(3_i64)] of Scheme::SchemeValue)
    lst.display_string.should eq("(1 2 3)")
  end

  it "displays a dotted pair" do
    Scheme::Cons.new(Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64)).display_string.should eq("(1 . 2)")
  end

  it "displays nested lists" do
    inner = Scheme.a_to_list([Scheme::SchemeInt.new(2_i64), Scheme::SchemeInt.new(3_i64)] of Scheme::SchemeValue)
    outer = Scheme.a_to_list([Scheme::SchemeInt.new(1_i64), inner] of Scheme::SchemeValue)
    outer.display_string.should eq("(1 (2 3))")
  end

  it "writes strings inside lists escaped" do
    lst = Scheme.a_to_list([Scheme::SchemeStr.new("a\nb")] of Scheme::SchemeValue)
    lst.write_string.should eq(%(("a\\nb")))
  end

  it "displays strings inside lists unescaped" do
    lst = Scheme.a_to_list([Scheme::SchemeStr.new("a\nb")] of Scheme::SchemeValue)
    lst.display_string.should eq("(a\nb)")
  end
end

describe Scheme::Macro do
  it "stores params, rest, body, env and name" do
    env = Scheme::Env.new
    body = [Scheme::SchemeInt.new(1_i64)] of Scheme::SchemeValue
    mac = Scheme::Macro.new(["x"], "rest", body, env, "mymacro")
    mac.params.should eq(["x"])
    mac.rest.should eq("rest")
    mac.body.should eq(body)
    mac.env.should be(env)
    mac.name.should eq("mymacro")
  end

  it "defaults name to macro" do
    Scheme::Macro.new([] of String, nil, [] of Scheme::SchemeValue, Scheme::Env.new).name.should eq("macro")
  end

  it "name is mutable" do
    mac = Scheme::Macro.new([] of String, nil, [] of Scheme::SchemeValue, Scheme::Env.new)
    mac.name = "renamed"
    mac.name.should eq("renamed")
  end

  it "displays as #<macro:name>" do
    mac = Scheme::Macro.new([] of String, nil, [] of Scheme::SchemeValue, Scheme::Env.new, "swap!")
    mac.display_string.should eq("#<macro:swap!>")
  end
end

describe Scheme::Builtin do
  it "stores name and arity" do
    b = Scheme::Builtin.new("plus", 0, -1) { |args| Scheme::SchemeInt.new(args.size.to_i64) }
    b.name.should eq("plus")
    b.min_arity.should eq(0)
    b.max_arity.should eq(-1)
  end

  it "invokes the given block via fn" do
    b = Scheme::Builtin.new("plus", 0, -1) { |args| Scheme::SchemeInt.new(args.size.to_i64) }
    result = b.fn.call([Scheme::NIL, Scheme::NIL] of Scheme::SchemeValue)
    result.as(Scheme::SchemeInt).value.should eq(2_i64)
  end

  it "displays as #<builtin:name>" do
    b = Scheme::Builtin.new("plus", 0, -1) { |_| Scheme::NIL.as(Scheme::SchemeValue) }
    b.display_string.should eq("#<builtin:plus>")
  end
end

describe Scheme::SchemeVector do
  it "displays elements space-separated inside #(...)" do
    v = Scheme::SchemeVector.new([Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64)] of Scheme::SchemeValue)
    v.display_string.should eq("#(1 2)")
  end

  it "writes strings quoted inside the vector" do
    v = Scheme::SchemeVector.new([Scheme::SchemeStr.new("a")] of Scheme::SchemeValue)
    v.write_string.should eq(%(#("a")))
    v.display_string.should eq("#(a)")
  end

  it "displays an empty vector" do
    Scheme::SchemeVector.new.display_string.should eq("#()")
  end
end

describe Scheme::SchemeBlob do
  it "stores the given bytes" do
    bytes = Bytes[1, 2, 3]
    Scheme::SchemeBlob.new(bytes).value.should eq(bytes)
  end

  it "displays as #<blob:N bytes>" do
    Scheme::SchemeBlob.new(Bytes[1, 2, 3]).display_string.should eq("#<blob:3 bytes>")
  end

  it "displays an empty blob" do
    Scheme::SchemeBlob.new(Bytes.empty).display_string.should eq("#<blob:0 bytes>")
  end

  it "write_string shows #u8(...) contents, per R7RS bytevector write syntax" do
    Scheme::SchemeBlob.new(Bytes[1, 2, 255]).write_string.should eq("#u8(1 2 255)")
  end

  it "write_string shows #u8() for an empty bytevector" do
    Scheme::SchemeBlob.new(Bytes.empty).write_string.should eq("#u8()")
  end
end

describe Scheme::SchemeRecordType do
  it "displays as #<record-type:name>" do
    Scheme::SchemeRecordType.new("point", ["x", "y"]).display_string.should eq("#<record-type:point>")
  end
end

describe Scheme::SchemeRecord do
  it "displays with its type name and field=value pairs" do
    t = Scheme::SchemeRecordType.new("point", ["x", "y"])
    r = Scheme::SchemeRecord.new(t, [Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64)] of Scheme::SchemeValue)
    r.display_string.should eq("#<point x=1 y=2>")
  end

  it "displays a record with no fields" do
    t = Scheme::SchemeRecordType.new("marker", [] of String)
    r = Scheme::SchemeRecord.new(t, [] of Scheme::SchemeValue)
    r.display_string.should eq("#<marker>")
  end
end

describe Scheme::SchemeSyntaxRules do
  it "displays as #<syntax-rules:name>" do
    Scheme::SchemeSyntaxRules.new("my-if", [] of String, [] of {Scheme::SchemeValue, Scheme::SchemeValue}).display_string.should eq("#<syntax-rules:my-if>")
  end
end

describe Scheme::SchemeParameter do
  it "displays as #<parameter>" do
    Scheme::SchemeParameter.new(Scheme::SchemeInt.new(1_i64)).display_string.should eq("#<parameter>")
  end
end

describe Scheme::SchemeValues do
  it "displays its items" do
    v = Scheme::SchemeValues.new([Scheme::SchemeInt.new(1_i64), Scheme::SchemeInt.new(2_i64)] of Scheme::SchemeValue)
    v.display_string.should eq("#<values 1 2>")
  end

  it "displays with no items" do
    Scheme::SchemeValues.new([] of Scheme::SchemeValue).display_string.should eq("#<values>")
  end
end

describe Scheme::SchemeContinuation do
  it "displays as #<continuation>" do
    Scheme::SchemeContinuation.new(1_i64).display_string.should eq("#<continuation>")
  end
end

describe Scheme::SchemeHashTable do
  it "displays with its entry count" do
    Scheme::SchemeHashTable.new.display_string.should eq("#<hash-table 0 entries>")
    entries = [{Scheme::SchemeSym.of("a").as(Scheme::SchemeValue), Scheme::SchemeInt.new(1_i64).as(Scheme::SchemeValue)}]
    h = Scheme::SchemeHashTable.new(entries)
    h.display_string.should eq("#<hash-table 1 entries>")
  end

  it "finds a key by equal?, not identity" do
    key1 = Scheme.a_to_list([Scheme::SchemeInt.new(1_i64)] of Scheme::SchemeValue)
    key2 = Scheme.a_to_list([Scheme::SchemeInt.new(1_i64)] of Scheme::SchemeValue)
    entries = [{key1.as(Scheme::SchemeValue), Scheme::SchemeInt.new(99_i64).as(Scheme::SchemeValue)}]
    h = Scheme::SchemeHashTable.new(entries)
    h.contains?(key2).should be_true
    h.get?(key2).should eq(Scheme::SchemeInt.new(99_i64))
  end

  it "reports absent keys as not found" do
    h = Scheme::SchemeHashTable.new
    h.contains?(Scheme::SchemeSym.of("z")).should be_false
    h.get?(Scheme::SchemeSym.of("z")).should be_nil
  end
end

describe Scheme::SchemePromise do
  it "displays as unforced before being forced" do
    thunk = Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }
    Scheme::SchemePromise.new(thunk).display_string.should eq("#<promise>")
  end

  it "displays as forced once forced" do
    thunk = Scheme::Builtin.new("dummy", 0, 0) { Scheme::NIL.as(Scheme::SchemeValue) }
    p = Scheme::SchemePromise.new(thunk)
    p.forced = true
    p.display_string.should eq("#<promise forced>")
  end
end
