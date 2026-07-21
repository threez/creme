require "../../../spec_helper"

private def w(src : String) : String
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme csv)) #{src}").write_string
end

private def run(src : String) : Scheme::SchemeValue
  interp = Scheme::Interpreter.new
  Scheme.run_source(interp, "(import (creme csv)) #{src}")
end

describe "csv module" do
  it "parses rows into a vector of vectors of strings" do
    w(%((csv-read "a,b\\n1,2\\n"))).should eq(%(#(#("a" "b") #("1" "2"))))
  end

  it "parses rows with a custom separator and quote char" do
    w(%((csv-read "a;'b;c';d" #\\; #\\'))).should eq(%(#(#("a" "b;c" "d"))))
  end

  it "parses rows with headers into an alist accessible via assoc/cdr" do
    w(%((cdr (assoc "b" (vector-ref (csv-read-headers "a,b\\n1,2\\n") 0))))).should eq(%("2"))
  end

  it "round-trips csv-write for a vector of rows" do
    w(%((csv-write (vector (vector "a" "b") (vector 1 2))))).should eq(%("a,b\\n1,2\\n"))
  end

  it "quotes a cell containing the separator under rfc quoting (the default)" do
    w(%((csv-write (list (list "a,b" "c"))))).should eq(%("\\"a,b\\",c\\n"))
  end

  it "never quotes under 'none quoting" do
    w(%((csv-write (list (list "a" "b")) #\\, 'none))).should eq(%("a,b\\n"))
  end

  it "quotes every cell under 'all quoting" do
    w(%((csv-write (list (list "a" 1)) #\\, 'all))).should eq(%("\\"a\\",\\"1\\"\\n"))
  end

  it "round-trips csv-write-headers" do
    w(%((csv-write-headers (list "a" "b") (list (list 1 2))))).should eq(%("a,b\\n1,2\\n"))
  end

  it "raises on malformed csv" do
    expect_raises(Scheme::SchemeRuntimeError, /csv-read: /) do
      run(%((csv-read "\\"unterminated")))
    end
  end

  it "streams rows through a writer and reads them back through a reader" do
    result = w(%(
      (let ((out (open-output-string)))
        (let ((w (csv-writer-open out)))
          (csv-writer? w)
          (csv-writer-row! w "a" "b")
          (csv-writer-row! w 1 2))
        (let* ((in (open-input-string (get-output-string out)))
               (r (csv-reader-open in))
               (row1 (csv-reader-read! r))
               (row2 (csv-reader-read! r))
               (row3 (csv-reader-read! r)))
          (list (csv-reader? r) row1 row2 (eof-object? row3))))
    ))
    result.should eq(%((#t #("a" "b") #("1" "2") #t)))
  end

  it "csv-reader-open accepts a tiny 4th chunk-size arg, forcing many internal refills, without affecting results" do
    result = w(%(
      (let* ((in (open-input-string "one,two\\nthree,four\\nfive,six"))
             (r (csv-reader-open in #\\, #\\" 4))
             (row1 (csv-reader-read! r))
             (row2 (csv-reader-read! r))
             (row3 (csv-reader-read! r))
             (row4 (csv-reader-read! r)))
        (list row1 row2 row3 (eof-object? row4)))
    ))
    result.should eq(%((#("one" "two") #("three" "four") #("five" "six") #t)))
  end
end
