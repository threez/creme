require "../../spec_helper"

private def interp
  Creme::Interpreter.new(library_search_path: ["./modules"])
end

private def r(src : String) : String
  Creme.run_source(interp, "(import (creme svg)) #{src}").as(Creme::SchemeStr).value
end

private def two_charts
  <<-SCHEME
  (svg-bar-chart-grid
   (list (cons "fib" (list (cons "crystal" 1) (cons "ruby" 5)))
         (cons "sum-to" (list (cons "crystal" 2) (cons "ruby" 6))))
   2 100 40)
  SCHEME
end

describe "svg module" do
  it "renders exactly one <svg> root, with a shared <style> block" do
    out = r(two_charts)
    out.scan(/<svg /).size.should eq(1)
    out.should start_with("<svg ")
    out.should end_with("</svg>")
    out.scan(/<style>/).size.should eq(1)
    out.should contain(".card{")
    out.should contain(".bar{")
    out.should contain(".title{")
  end

  it "renders one card box (class=\"card\") per chart" do
    out = r(two_charts)
    cards = out.scan(/<rect[^>]*class="card"[^>]*>/)
    cards.size.should eq(2)
  end

  it "renders one title per chart, matching its own label" do
    out = r(two_charts)
    out.should contain(">fib<")
    out.should contain(">sum-to<")
  end

  it "renders bar rects with a bar class and a stroke border, fill/stroke still per-bar" do
    out = r(two_charts)
    bars = out.scan(/<rect[^>]*class="bar"[^>]*>/)
    bars.size.should eq(4) # 2 charts x 2 bars each
    bars.each do |m|
      m[0].should match(/fill="hsl/)
      m[0].should match(/stroke="hsl/)
    end
  end

  it "rounds coordinates to 2 decimal places" do
    out = r(two_charts)
    out.scan(/\s(?:x|y|width|height)="([^"]+)"/).each do |m|
      m[1].should match(/^-?\d+\.\d{2}$/)
    end
  end

  it "lays out the second chart's card to the right of the first (columns=2)" do
    out = r(two_charts)
    card_xs = out.scan(/<rect[^>]*class="card"[^>]*>/).map { |tag| tag[0][/\bx="([\d.]+)"/, 1].to_f }
    card_xs.size.should eq(2)
    (card_xs[1] > card_xs[0]).should be_true
  end

  it "wraps to a new row after `columns` charts, at the same x as the first" do
    out = r(<<-SCHEME)
      (svg-bar-chart-grid
       (list (cons "a" (list (cons "x" 1))) (cons "b" (list (cons "x" 2))) (cons "c" (list (cons "x" 3))))
       2 100 40)
      SCHEME
    ys = out.scan(/<rect[^>]*class="card"[^>]*>/).map { |tag| tag[0][/\by="([\d.]+)"/, 1].to_f }
    xs = out.scan(/<rect[^>]*class="card"[^>]*>/).map { |tag| tag[0][/\bx="([\d.]+)"/, 1].to_f }
    xs.size.should eq(3)
    xs[2].should eq(xs[0]) # third card wraps back to column 0's x
    (ys[2] > ys[0]).should be_true # but on a lower row
  end

  it "gives the SAME label the SAME fill color across two different charts" do
    out = r(two_charts)
    fills = out.scan(/<rect[^>]*fill="(hsl[^"]+)"/).map { |m| m[1] }
    fills.size.should eq(4)
    # order: chart1/crystal, chart1/ruby, chart2/crystal, chart2/ruby
    fills[0].should eq(fills[2]) # crystal same color in both charts
    fills[1].should eq(fills[3]) # ruby same color in both charts
    fills[0].should_not eq(fills[1])
  end

  it "renders a #f value as a zero-height column labeled n/a" do
    out = r(%q((svg-bar-chart-grid (list (cons "t" (list (cons "missing" #f) (cons "present" 5)))) 1 100 40)))
    out.should contain(%(height="0.00"))
    out.should contain(">n/a<")
  end
end
