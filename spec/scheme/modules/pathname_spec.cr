require "../../spec_helper"

private def w(src : String) : String
  interp = Creme::Interpreter.new(library_search_path: ["./modules"])
  Creme.run_source(interp, "(import (scheme base) (creme pathname)) #{src}").write_string
end

describe "pathname module" do
  it "extracts dirname" do
    w(%((pathname->string (pathname-dirname (make-pathname "/a/b/c"))))).should eq(%("/a/b"))
    w(%((pathname->string (pathname-dirname (make-pathname "a/b"))))).should eq(%("a"))
    w(%((pathname->string (pathname-dirname (make-pathname "a"))))).should eq(%("."))
    w(%((pathname->string (pathname-dirname (make-pathname "/a"))))).should eq(%("/"))
    w(%((pathname->string (pathname-dirname (make-pathname "/"))))).should eq(%("/"))
    w(%((pathname->string (pathname-dirname (make-pathname ""))))).should eq(%("."))
  end

  it "extracts basename" do
    w(%((pathname->string (pathname-basename (make-pathname "/a/b/c"))))).should eq(%("c"))
    w(%((pathname->string (pathname-basename (make-pathname "a/"))))).should eq(%("a"))
    w(%((pathname->string (pathname-basename (make-pathname "/"))))).should eq(%("/"))
    w(%((pathname->string (pathname-basename (make-pathname ""))))).should eq(%("."))
  end

  it "strips a given extension from basename" do
    w(%((pathname->string (pathname-basename (make-pathname "file.rb") ".rb")))).should eq(%("file"))
    w(%((pathname->string (pathname-basename (make-pathname "file.tar.gz") "*")))).should eq(%("file.tar"))
    w(%((pathname->string (pathname-basename (make-pathname "file.rb") ".txt")))).should eq(%("file.rb"))
  end

  it "extracts extname" do
    w(%((pathname-extname (make-pathname "file.tar.gz")))).should eq(%(".gz"))
    w(%((pathname-extname (make-pathname "file")))).should eq(%(""))
    w(%((pathname-extname (make-pathname ".bashrc")))).should eq(%(""))
    w(%((pathname-extname (make-pathname ".file.rb")))).should eq(%(".rb"))
    w(%((pathname-extname (make-pathname "file.")))).should eq(%("."))
  end

  it "splits into dirname and basename as two values" do
    w(<<-SCHEME).should eq(%(("a/b" "c")))
      (call-with-values
       (lambda () (pathname-split (make-pathname "a/b/c")))
       (lambda (dir base) (list (pathname->string dir) (pathname->string base))))
      SCHEME
  end

  it "reports absolute?/relative?" do
    w(%((pathname-absolute? (make-pathname "/a")))).should eq("#t")
    w(%((pathname-absolute? (make-pathname "a")))).should eq("#f")
    w(%((pathname-relative? (make-pathname "a")))).should eq("#t")
  end

  it "joins segments, later absolute segments override earlier ones" do
    w(%((pathname->string (pathname-join (make-pathname "a") "b" "c")))).should eq(%("a/b/c"))
    w(%((pathname->string (pathname-join (make-pathname "a") "/b")))).should eq(%("/b"))
    w(%((pathname->string (pathname-join (make-pathname "/a/") "b")))).should eq(%("/a/b"))
  end

  it "joins a pathname segment, not just plain strings" do
    w(%((pathname->string (pathname-join (make-pathname "a") (make-pathname "b"))))).should eq(%("a/b"))
  end

  it "cleans up . and .. components lexically" do
    w(%((pathname->string (pathname-cleanpath (make-pathname "/a/./b/../c"))))).should eq(%("/a/c"))
    w(%((pathname->string (pathname-cleanpath (make-pathname "a/../../b"))))).should eq(%("../b"))
    w(%((pathname->string (pathname-cleanpath (make-pathname "/../a"))))).should eq(%("/a"))
    w(%((pathname->string (pathname-cleanpath (make-pathname "a/.."))))).should eq(%("."))
  end

  it "computes parent as join with .." do
    w(%((pathname->string (pathname-parent (make-pathname "/a/b"))))).should eq(%("/a"))
  end

  it "lists each real filename component, ignoring empty segments" do
    w(%((pathname-each-filename (make-pathname "/a//b/c/")))).should eq(%(("a" "b" "c")))
  end

  it "substitutes an extension" do
    w(%((pathname->string (pathname-sub-ext (make-pathname "a/file.rb") ".txt")))).should eq(%("a/file.txt"))
    w(%((pathname->string (pathname-sub-ext (make-pathname "file") ".txt")))).should eq(%("file.txt"))
    w(%((pathname->string (pathname-sub-ext (make-pathname "/file.rb") ".txt")))).should eq(%("/file.txt"))
  end

  it "distinguishes pathname? from other values" do
    w(%((list (pathname? (make-pathname "a")) (pathname? "a")))).should eq("(#t #f)")
  end
end
