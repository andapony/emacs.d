;;; rjd-shr-math.el --- Render MathML as Unicode text in shr  -*- lexical-binding: t -*-

;;; Commentary:
;; Renders the MathML that KaTeX and MathJax embed in a page into readable
;; Unicode text, so that eww shows a formula rather than its TeX source.
;;
;; A page typeset with either library ships each formula twice: a MathML
;; tree, and a pile of positioned spans carrying the visual glyphs, marked
;; `aria-hidden' so that screen readers skip it.  shr renders the second
;; copy unless `shr-discard-aria-hidden' is non-nil -- set that too, or
;; every formula is still followed by a scrambled echo of itself.
;;
;; For the first copy, shr's own `shr-tag-math' looks inside <semantics>
;; for the <annotation> holding the original TeX and prints that.  It is a
;; deliberate choice and a reasonable one -- the TeX is at least the
;; author's own notation -- but it means eww shows
;;
;;     \mathrm{Verbosity}=\frac{|\text{flagged}\cup\text{clone}|}{\mathrm{LOC}}
;;
;; where this file shows
;;
;;     Verbosity = ∣flagged ∪ clone∣ / LOC
;;
;; The MathML is the better source to render from, despite the TeX looking
;; closer to what we want.  It is a parsed tree rather than a string, shr
;; has already handed it to us as a dom, and the library has resolved every
;; macro to a Unicode character -- \cup is already ∪ -- so there is no TeX
;; to interpret, only a layout to flatten.
;;
;; Flattening loses two dimensions.  A fraction becomes an inline quotient
;; and scripts become either Unicode superscripts or `^'/`_' notation, both
;; parenthesised where precedence would otherwise be ambiguous.  Nothing
;; here tries to be TeX: the aim is a formula that reads correctly in a
;; sentence, on a terminal frame, with no LaTeX installation.
;;
;; Enable with `rjd/shr-math-mode'.  It is global, and applies anywhere shr
;; renders -- eww, mu4e, elfeed -- not just eww.
;;
;; CAVEAT: this overrides `shr-tag-math' with `:around' advice.  That
;; function is not private, but it is also not an extension point, and it
;; arrived only in Emacs 30.  If a formula reverts to TeX source the advice
;; has fallen off; if one disappears, this file's renderer returned an
;; empty string for markup it did not expect, and turning the mode off
;; restores shr's behaviour.

;;; Code:

(require 'dom)
(require 'seq)
(require 'subr-x)

(declare-function shr-insert "shr" (text))
(declare-function shr-ensure-newline "shr" ())


;;; Symbol tables

(defconst rjd/shr-math--spaced-operators
  '("=" "≠" "≈" "≃" "≅" "≡" "<" ">" "≤" "≥" "≪" "≫" "∼" "∝" "≔"
    "+" "−" "±" "∓" "×" "÷" "∗" "∘"
    "∪" "∩" "∖" "⊂" "⊃" "⊆" "⊇" "∈" "∉" "∋"
    "→" "←" "↔" "↦" "⇒" "⇐" "⇔" "∧" "∨" "⊕" "⊗")
  "Operators rendered with a space on either side.
Relations and binary operators only: delimiters, punctuation and things
like ⋅ read better closed up, and an <mo> not listed here is emitted as
it stands.")

(defconst rjd/shr-math--large-operators
  '("∑" "∏" "∐" "∫" "∬" "∭" "∮" "⋃" "⋂" "⨆" "⨁" "⨂"
    "lim" "max" "min" "sup" "inf")
  "Operators that take limits and are followed by the expression they act on.
Their scripts get a trailing space, so that ∑ over f applied to mass(f)
comes out as \"∑_f mass(f)\" rather than \"∑_fmass(f)\".")

(defconst rjd/shr-math--superscripts
  '((?0 . ?⁰) (?1 . ?¹) (?2 . ?²) (?3 . ?³) (?4 . ?⁴) (?5 . ?⁵)
    (?6 . ?⁶) (?7 . ?⁷) (?8 . ?⁸) (?9 . ?⁹)
    (?+ . ?⁺) (?- . ?⁻) (?− . ?⁻) (?= . ?⁼) (?\( . ?⁽) (?\) . ?⁾)
    (?n . ?ⁿ) (?i . ?ⁱ))
  "Characters with a Unicode superscript form.
Deliberately short: a partial run of raised characters reads worse than
none, so a script is raised only when every character in it maps.")

(defconst rjd/shr-math--subscripts
  '((?0 . ?₀) (?1 . ?₁) (?2 . ?₂) (?3 . ?₃) (?4 . ?₄) (?5 . ?₅)
    (?6 . ?₆) (?7 . ?₇) (?8 . ?₈) (?9 . ?₉)
    (?+ . ?₊) (?- . ?₋) (?− . ?₋) (?= . ?₌) (?\( . ?₍) (?\) . ?₎)
    (?a . ?ₐ) (?e . ?ₑ) (?i . ?ᵢ) (?j . ?ⱼ) (?k . ?ₖ) (?l . ?ₗ)
    (?m . ?ₘ) (?n . ?ₙ) (?o . ?ₒ) (?p . ?ₚ) (?r . ?ᵣ) (?s . ?ₛ)
    (?t . ?ₜ) (?u . ?ᵤ) (?v . ?ᵥ) (?x . ?ₓ))
  "Characters with a Unicode subscript form.
See `rjd/shr-math--superscripts' for why the table is not larger.")

(defconst rjd/shr-math--delimiters
  '((?\( . ?\)) (?\[ . ?\]) (?{ . ?}) (?∣ . ?∣) (?| . ?|) (?‖ . ?‖))
  "Delimiter pairs recognised when deciding whether to add parentheses.")


;;; Text helpers

(defun rjd/shr-math--squeeze (string)
  "Collapse runs of spaces in STRING and trim each line.
Spacing is introduced per operator, so abutting operators and explicit
<mspace> elements would otherwise leave gaps."
  (string-join
   (mapcar (lambda (line)
             (string-trim (replace-regexp-in-string "[ \t]+" " " line)))
           (split-string string "\n"))
   "\n"))

(defun rjd/shr-math--delimited-p (string)
  "Non-nil if STRING is enclosed in one matching pair of delimiters.
Enclosed means the opening delimiter is closed by the final character and
not before it, so \"(a)\" qualifies but \"(a)+(b)\" does not."
  (and (> (length string) 1)
       (let* ((open (aref string 0))
              (close (alist-get open rjd/shr-math--delimiters)))
         (and close
              (eq close (aref string (1- (length string))))
              ;; A bar delimiter is its own closer, so there is no nesting
              ;; to scan for -- ∣a∣ is as deep as it gets.
              (or (eq open close)
                  (let ((depth 0)
                        (last (1- (length string)))
                        (enclosed t))
                    (dotimes (i (length string))
                      (let ((char (aref string i)))
                        (cond ((alist-get char rjd/shr-math--delimiters)
                               (setq depth (1+ depth)))
                              ((rassq char rjd/shr-math--delimiters)
                               (setq depth (1- depth)))))
                      (when (and (zerop depth) (< i last))
                        (setq enclosed nil)))
                    enclosed))))))

(defun rjd/shr-math--wrap (string)
  "Parenthesise STRING unless it is a single character or already delimited.
For operands whose extent has to be unambiguous however short they are --
the argument of a root, or a script written with `^' or `_'."
  (if (or (length< string 2) (rjd/shr-math--delimited-p string))
      string
    (concat "(" string ")")))

(defun rjd/shr-math--wrap-compound (string)
  "Parenthesise STRING only if it contains a space and is not already delimited.
For operands an adjacent operator already separates, where parentheses
around every atom would be noise: LOC needs none as a denominator, but
∑_f mass(f) does."
  (if (or (not (string-search " " string))
          (rjd/shr-math--delimited-p string))
      string
    (concat "(" string ")")))

(defun rjd/shr-math--script (string table prefix)
  "Render STRING as a script, raised or lowered through TABLE if it maps.
Otherwise fall back to PREFIX -- `^' or `_' -- and a wrapped STRING."
  (if (and (not (string-empty-p string))
           (seq-every-p (lambda (char) (assq char table)) string))
      (concat (mapcar (lambda (char) (alist-get char table)) string))
    (concat prefix (rjd/shr-math--wrap string))))


;;; MathML rendering

(defun rjd/shr-math--children (node)
  "Render every child of NODE, concatenated."
  (mapconcat #'rjd/shr-math--render (dom-children node) ""))

(defun rjd/shr-math--nth-child (node n)
  "Render the Nth element child of NODE.
Whitespace text nodes between elements are skipped, so that positional
arguments -- a fraction's numerator, a script's base -- are counted the
way the MathML spec counts them."
  (let ((children (seq-remove #'stringp (dom-children node))))
    (if (nth n children)
        (rjd/shr-math--render (nth n children))
      "")))

(defun rjd/shr-math--operator (node)
  "Render NODE, an <mo> element, spacing it if it is a relation."
  (let ((operator (string-trim (dom-inner-text node))))
    (if (member operator rjd/shr-math--spaced-operators)
        (concat " " operator " ")
      operator)))

(defun rjd/shr-math--scripted (node table prefix)
  "Render NODE's base followed by its script, through TABLE and PREFIX.
NODE is an <msub>, <msup>, <munder> or <mover>.  A large operator keeps a
space after its script -- see `rjd/shr-math--large-operators'."
  (let ((base (rjd/shr-math--nth-child node 0))
        (script (rjd/shr-math--nth-child node 1)))
    (concat base
            (rjd/shr-math--script script table prefix)
            (when (member base rjd/shr-math--large-operators) " "))))

(defun rjd/shr-math--render (node)
  "Render NODE, a MathML element or text node, as a string."
  (cond
   ((stringp node) (string-trim node))
   ((not (consp node)) "")
   (t
    (pcase (dom-tag node)
      ;; Tokens.  <mi> arrives one letter per element for an upright word
      ;; like Verbosity, which is why token text is concatenated with no
      ;; separator and all spacing comes from operators.
      ((or 'mi 'mn 'ms 'mtext) (string-trim (dom-inner-text node)))
      ('mo (rjd/shr-math--operator node))
      ('mspace " ")
      ('mphantom "")
      ;; The TeX source shr would otherwise print, and the only part of
      ;; <semantics> we do not want.
      ((or 'annotation 'annotation-xml) "")
      ('mfrac
       (let ((numerator (rjd/shr-math--wrap-compound
                         (rjd/shr-math--nth-child node 0)))
             (denominator (rjd/shr-math--wrap-compound
                           (rjd/shr-math--nth-child node 1))))
         ;; Space the solidus only when an operand is more than an atom:
         ;; a/b is clearer closed up, (x + 1) / (y + 2) is not.
         (if (or (string-search " " numerator) (string-search " " denominator))
             (concat numerator " / " denominator)
           (concat numerator "/" denominator))))
      ('msqrt (concat "√" (rjd/shr-math--wrap (rjd/shr-math--children node))))
      ('mroot (concat (rjd/shr-math--script (rjd/shr-math--nth-child node 1)
                                            rjd/shr-math--superscripts "^")
                      "√"
                      (rjd/shr-math--wrap (rjd/shr-math--nth-child node 0))))
      ('msup (rjd/shr-math--scripted node rjd/shr-math--superscripts "^"))
      ('msub (rjd/shr-math--scripted node rjd/shr-math--subscripts "_"))
      ('msubsup
       (concat (rjd/shr-math--nth-child node 0)
               (rjd/shr-math--script (rjd/shr-math--nth-child node 1)
                                     rjd/shr-math--subscripts "_")
               (rjd/shr-math--script (rjd/shr-math--nth-child node 2)
                                     rjd/shr-math--superscripts "^")))
      ;; Limits are scripts once the vertical dimension is gone.  An
      ;; accent -- a bar or a hat over the base -- is a combining
      ;; character, so appending it composes rather than displaces.
      ('munder (rjd/shr-math--scripted node rjd/shr-math--subscripts "_"))
      ('mover
       (if (equal (dom-attr node 'accent) "true")
           (concat (rjd/shr-math--nth-child node 0)
                   (rjd/shr-math--nth-child node 1))
         (rjd/shr-math--scripted node rjd/shr-math--superscripts "^")))
      ('munderover
       (concat (rjd/shr-math--nth-child node 0)
               (rjd/shr-math--script (rjd/shr-math--nth-child node 1)
                                     rjd/shr-math--subscripts "_")
               (rjd/shr-math--script (rjd/shr-math--nth-child node 2)
                                     rjd/shr-math--superscripts "^")
               (when (member (rjd/shr-math--nth-child node 0)
                             rjd/shr-math--large-operators)
                 " ")))
      ('mtable (mapconcat #'rjd/shr-math--render (dom-by-tag node 'mtr) "\n"))
      ('mtr (mapconcat #'rjd/shr-math--render (dom-by-tag node 'mtd) " "))
      ;; <math>, <semantics>, <mrow>, <mstyle>, <mpadded>, <menclose> and
      ;; anything unforeseen: transparent wrappers, so render through.
      (_ (rjd/shr-math--children node))))))


;;; shr integration

(defun rjd/shr-math--tag-math (original dom)
  "Render DOM, a <math> element, as Unicode text.
Falls back to ORIGINAL -- shr's `shr-tag-math', which prints the TeX
annotation -- when there is no MathML to render, as on a page that
embeds the TeX and nothing else."
  (let ((text (rjd/shr-math--squeeze (rjd/shr-math--children dom))))
    (if (string-empty-p text)
        (funcall original dom)
      ;; Only an <mtable> produces newlines, and shr folds whitespace, so
      ;; the line structure has to be put back through shr itself.
      (let ((lines (split-string text "\n")))
        (while lines
          (shr-insert (pop lines))
          (when lines (shr-ensure-newline)))))))

;;;###autoload
(define-minor-mode rjd/shr-math-mode
  "Render MathML as Unicode text wherever shr renders HTML.
Without this, `shr-tag-math' prints the TeX source of a formula
typeset by KaTeX or MathJax.  Set `shr-discard-aria-hidden' as well,
or each formula is followed by the scrambled visual copy."
  :global t
  :group 'shr
  (if rjd/shr-math-mode
      (advice-add 'shr-tag-math :around #'rjd/shr-math--tag-math)
    (advice-remove 'shr-tag-math #'rjd/shr-math--tag-math)))

(provide 'rjd-shr-math)
;;; rjd-shr-math.el ends here
