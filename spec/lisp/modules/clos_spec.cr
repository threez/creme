require "../../spec_helper"

private def w(src : String) : String
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'clos) #{src}").write_string
end

private def run(src : String) : LISP::LispValue
  interp = LISP::Interpreter.new
  LISP.run_source(interp, "(require 'clos) #{src}")
end

describe "clos module" do
  it "defines slots with readers/initargs and makes instances" do
    w(<<-LISP
      (defclass book ()
        ((title :reader book-title :initarg :title)
         (author :reader book-author :initarg :author)))
      (define b (make-instance 'book :title "ANSI Common Lisp" :author "Paul Graham"))
      (list (book-title b) (book-author b))
      LISP
    ).should eq(%(("ANSI Common Lisp" "Paul Graham")))
  end

  it "supports :accessor (reader + set-<name>! writer) and :initform defaults" do
    w(<<-LISP
      (defclass counter ()
        ((count :accessor counter-count :initarg :count :initform 0)))
      (define c (make-instance 'counter))
      (define before (counter-count c))
      (set-counter-count! c 5)
      (list before (counter-count c))
      LISP
    ).should eq("(0 5)")
  end

  it "raises on an unknown initarg" do
    expect_raises(LISP::LispRuntimeError, /make-instance: unknown initarg/) do
      run(<<-LISP
        (defclass point () ((x :initarg :x)))
        (make-instance 'point :y 1)
        LISP
      )
    end
  end

  it "raises reading an unbound slot" do
    expect_raises(LISP::LispRuntimeError, /slot-value: slot 'x' is unbound/) do
      run(<<-LISP
        (defclass point () ((x :initarg :x)))
        (slot-value (make-instance 'point) 'x)
        LISP
      )
    end
  end

  it "inherits slots across a single superclass, child slots override" do
    w(<<-LISP
      (defclass shape () ((color :reader shape-color :initarg :color :initform "black")))
      (defclass circle (shape) ((radius :reader circle-radius :initarg :radius)))
      (define c (make-instance 'circle :radius 3 :color "red"))
      (list (shape-color c) (circle-radius c) (instance-of? c 'shape) (instance-of? c 'circle))
      LISP
    ).should eq(%(("red" 3 #t #t)))
  end

  it "dispatches defmethod by the runtime class of the first argument" do
    w(<<-LISP
      (defclass shape () ())
      (defclass circle (shape) ((radius :initarg :radius)))
      (defclass square (shape) ((side :initarg :side)))
      (defmethod area ((s circle)) (* 3.14 (slot-value s 'radius) (slot-value s 'radius)))
      (defmethod area ((s square)) (* (slot-value s 'side) (slot-value s 'side)))
      (area (make-instance 'square :side 4))
      LISP
    ).should eq("16")
  end

  it "falls back to a superclass method when the subclass has none, via inheritance" do
    w(<<-LISP
      (defclass animal () ((name :reader animal-name :initarg :name)))
      (defclass dog (animal) ())
      (defmethod speak ((a animal)) (string-append (animal-name a) " makes a sound"))
      (speak (make-instance 'dog :name "Rex"))
      LISP
    ).should eq(%("Rex makes a sound"))
  end

  it "supports call-next-method to extend an inherited method" do
    w(<<-LISP
      (defclass animal () ((name :reader animal-name :initarg :name)))
      (defclass dog (animal) ())
      (defmethod speak ((a animal)) (string-append (animal-name a) " makes a sound"))
      (defmethod speak ((d dog)) (string-append (call-next-method) " (a bark)"))
      (speak (make-instance 'dog :name "Rex"))
      LISP
    ).should eq(%("Rex makes a sound (a bark)"))
  end

  it "raises when no applicable method exists" do
    expect_raises(LISP::LispRuntimeError, /area: no applicable method/) do
      run(<<-LISP
        (defclass shape () ())
        (defgeneric area (s))
        (area (make-instance 'shape))
        LISP
      )
    end
  end

  it "raises call-next-method with no next method" do
    expect_raises(LISP::LispRuntimeError, /call-next-method: no next method/) do
      run(<<-LISP
        (defclass animal () ())
        (defmethod speak ((a animal)) (call-next-method))
        (speak (make-instance 'animal))
        LISP
      )
    end
  end

  it "raises using defclass/make-instance before (require 'clos)" do
    expect_raises(LISP::LispRuntimeError, /defclass: call \(require 'clos\) first/) do
      LISP.run_source(LISP::Interpreter.new, "(defclass book () ())")
    end
  end
end
