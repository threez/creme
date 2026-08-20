require "../../spec_helper"

private def interp
  Creme::Interpreter.new(library_search_path: ["./modules"])
end

private def r(src : String) : String
  Creme.run_source(interp, "(import (creme color)) #{src}").as(Creme::SchemeStr).value
end

private def num(src : String) : Float64
  Creme.run_source(interp, "(import (creme color)) #{src}").write_string.to_f
end

describe "color module" do
  it "constructs a color and exposes its components" do
    num(%((hsl-hue (hsl 10 20 30)))).should eq(10.0)
    num(%((hsl-saturation (hsl 10 20 30)))).should eq(20.0)
    num(%((hsl-lightness (hsl 10 20 30)))).should eq(30.0)
  end

  it "renders a color as a CSS hsl() string, rounded to 2 decimal places" do
    r(%q((color->css (hsl 200 65 82)))).should eq("hsl(200.00, 65.00%, 82.00%)")
    r(%q((color->css (hsl 18.841796875 65 41)))).should eq("hsl(18.84, 65.00%, 41.00%)")
  end

  it "color-darken reduces lightness by percent of its current value, leaving hue/saturation alone" do
    num(%((hsl-lightness (color-darken (hsl 10 20 80) 50)))).should eq(40.0)
    num(%((hsl-hue (color-darken (hsl 10 20 80) 50)))).should eq(10.0)
    num(%((hsl-saturation (color-darken (hsl 10 20 80) 50)))).should eq(20.0)
    num(%((hsl-lightness (color-darken (hsl 10 20 80) 100)))).should eq(0.0)
    num(%((hsl-lightness (color-darken (hsl 10 20 80) 0)))).should eq(80.0)
  end

  it "color-lighten moves lightness toward 100 by percent of the remaining headroom" do
    num(%((hsl-lightness (color-lighten (hsl 10 20 50) 50)))).should eq(75.0)
    num(%((hsl-lightness (color-lighten (hsl 10 20 50) 100)))).should eq(100.0)
  end

  it "darkening twice by 50% is strictly darker than darkening once" do
    once = num(%((hsl-lightness (color-darken (hsl 0 0 80) 50))))
    twice = num(%((hsl-lightness (color-darken (color-darken (hsl 0 0 80) 50) 50))))
    (twice < once).should be_true
    twice.should eq(20.0)
  end

  it "categorical-color is deterministic and gives different labels different hues" do
    h1a = num(%((hsl-hue (categorical-color "crystal"))))
    h1b = num(%((hsl-hue (categorical-color "crystal"))))
    h2 = num(%((hsl-hue (categorical-color "ruby"))))
    h1a.should eq(h1b)
    h1a.should_not eq(h2)
  end

  it "categorical-color uses a fixed pastel saturation/lightness" do
    num(%((hsl-saturation (categorical-color "node")))).should eq(65.0)
    num(%((hsl-lightness (categorical-color "node")))).should eq(82.0)
  end
end
