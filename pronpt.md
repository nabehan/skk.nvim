/usr/share/skk/SKK-JISYO.L
/usr/share/skk/SKK-JISYO.mazegaki
/usr/share/skk/SKK-JISYO.requested
/usr/share/skk/SKK-JISYO.pubdic+
/usr/share/skk/SKK-JISYO.law
/usr/share/skk/SKK-JISYO.jinmei
/usr/share/skk/SKK-JISYO.assoc

新人研修の場面では、

./test.sh の 実機での実行結果、いくつか Faild があるようです。

ここまでの更新はリポジトリに反映しました。

https://github.com/nabehan/skk.nvim

ひらがな(またはカタカナ)モードから、/ の打鍵でabbrevモード へ遷移し、変換および確定後に、遷移前のひらがな(またはカタカナ)モードに戻る動作は確認できました。次は、ddskkが実装しているのと同様、abbrevモードで入力中に<C-q>を打鍵した際、全角英数に変換して確定する動作を実装してください。例を示すと、

▽manager<C-q> ｍａｎａｇｅｒ (遷移前のひらがなモードまたは カタカナモード に戻る)

バグの発生です。

この更新を加えてから、ひらがなモードとカタカナモードで、L(つまりshift-l) を打鍵しても全角英数モードに遷移しません。代りに Sticky Shift ;打鍵と同様、▽が表示され変換プレエディットが開始されてしまいます。l打鍵は期待どおり半角英数モードに遷移してくれます。

shift-l打鍵による変換プレエディット開始バグの修正。

abbrevモードへの<C-q>機能の追加。

その他、必要な修正を含めて生成を続けてください。優先順位はお任せします。
