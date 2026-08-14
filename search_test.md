# Neovim 検索・置換・テキスト操作 テスト用ドキュメント

このファイルは Neovim の検索操作（`/`, `?`）、カーソル移動（`f`, `t`, `*`, `#`）、正規表現パターンマッチング、および文字列置換（`:%s`）の挙動をテストするために作成されたサンプルテキストです。日本語、英語、各種プログラミング言語のコードブロックが含まれています。

---

## 1. 日本語テキストの検索と移動テスト (Japanese Text Search Test)

日本語の文章内での検索操作をテストします。マルチバイト文字（全角文字）に対する `/` 検索や、ひらがな・カタカナ・漢字の混在パターンを確認してください。



### 1.1 形態素とキーワード検索
Neovim で日本語を検索する場合、検索文字列の正確な一致が求められます。
例えば「検索」という単語は、この段落内に何度も登場します。検索機能（Search function）を利用して「検索」をハイライト表示し、`n` キーで次へ、`N` キーで前へ移動できるかテストしてください。

* **重要キーワード:** データベース, ネットワーク, 非同期処理, アルゴリズム, 暗号化
* **類似キーワード:** データの検索, ネットの接続, 同期処理の実行, アルゴリズムの評価, 暗号化の復号

また、「バッファ」「ウィンドウ」「タブ」「レジスタ」「マッピング」といった Vim/Neovim 用語のカタカナ表記についても、全角カタカナの検索が正しく機能するか確認します。バッファを切り替える操作や、レジスタに文字列をヤンク（コピー）する操作は頻繁に行われます。

### 1.2 長文エッセイ（マルチバイト文字の連続）
ソフトウェア開発において、エディタの選択は生産性に直列に影響を与えます。特に Neovim は Vim の伝統を継承しつつ、Lua による柔軟な拡張性、組み込みの LSP (Language Server Protocol) クライアント、Tree-sitter による高度な構文ハイライト機能などを備えており、現代のエディタとして非常に強力です。

検索操作は単に文字を探すだけでなく、コードの構造を把握し、リファクタリングを行うための第一歩となります。前方検索 `/` と後方検索 `?` を使い分けることで、長大なログファイルやドキュメント内を瞬時に移動できます。

---

## 2. 英語テキストと英数字・記号の検索テスト (English & Symbol Search Test)

英語テキストでは、大文字・小文字の区別（`ignorecase`, `smartcase` 設定）や、単語単位の移動（`w`, `b`, `e`）、記号を含む正規表現のテストを行います。

### 2.1 Sample Technical Overview
Neovim is a refactor, and sometimes redone, fork of Vim. It is designed to be easily extensible, embeddable, and maintainable. It includes an embedded Lua interpreter, a built-in terminal emulator, and asynchronous plugin architecture.

* **Case Sensitivity Test:**
  * apple, Apple, APPLE, ApPlE
  * buffer, Buffer, BUFFER, buff3r
  * search, Search, SEARCH, re-search, pre-search

* **Symbol & Pattern Test:**
  * Email addresses: `user@example.com`, `admin.test-123@sub.domain.org`
  * IP addresses: `192.168.1.1`, `10.0.0.255`, `127.0.0.1`
  * URLs: `https://neovim.io`, `http://localhost:8080/api/v1/users?id=42&sort=desc`
  * File paths: `/usr/local/bin/nvim`, `C:\Users\Username\AppData\Local\nvim\init.lua`

Try searching for word boundaries using `\<word\>` pattern in Vim search. For example, searching for `\<in\>` should match "in" but not "inside" or "plugin".

---

## 3. プログラミング言語コードブロック (Code Blocks Test)

コード内でのシンボル検索、変数名の置換、記号（ブラケット、演算子）の検索テスト用です。

### 3.1 Python (アルゴリズムと非同期処理)
```python
import asyncio
import re
from typing import List, Dict, Optional

class SearchProcessor:
    def __init__(self, target_pattern: str):
        self.pattern = re.compile(target_pattern, re.IGNORECASE)
        self.results: List[Dict[str, str]] = []

    async def process_text(self, text_line: str, line_num: int) -> Optional[Dict[str, str]]:
        """Search target pattern within a given line of text."""
        await asyncio.sleep(0.001)  # Simulate async I/O
        match = self.pattern.search(text_line)
        if match:
            result = {
                "line": str(line_num),
                "matched": match.group(0),
                "context": text_line.strip()
            }
            self.results.append(result)
            return result
        return None

async def main():
    processor = SearchProcessor(r"neovim|vim")
    sample_lines = [
        "Neovim provides asynchronous plugin infrastructure.",
        "Vim has a long history starting from Vi.",
        "Emacs is another popular text editor.",
        "Lua scripts make Neovim extremely fast."
    ]

    tasks = [processor.process_text(line, i + 1) for i, line in enumerate(sample_lines)]
    await asyncio.gather(*tasks)

    for item in processor.results:
        print(f"Line {item['line']}: Found '{item['matched']}' in context: {item['context']}")

if __name__ == "__main__":
    asyncio.run(main())
```

### 3.2 TypeScript / JavaScript (フロントエンド・LSP 関連)
```typescript
interface SearchConfig {
    caseSensitive: boolean;
    useRegex: boolean;
    maxResults?: number;
}

type SearchResult<T> = {
    item: T;
    score: number;
    matches: Array<{ indices: [number, number]; key: string }>;
};

class FuzzySearchEngine<T extends Record<string, any>> {
    private items: T[];
    private config: SearchConfig;

    constructor(items: T[], config: SearchConfig = { caseSensitive: false, useRegex: false }) {
        this.items = items;
        this.config = config;
    }

    public executeQuery(query: string, keys: Array<keyof T>): SearchResult<T>[] {
        if (!query || query.trim() === "") {
            return [];
        }

        const results: SearchResult<T>[] = [];
        const flags = this.config.caseSensitive ? 'g' : 'gi';
        const regex = this.config.useRegex 
            ? new RegExp(query, flags)
            : new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags);

        for (const item of this.items) {
            for (const key of keys) {
                const value = String(item[key]);
                if (regex.test(value)) {
                    results.push({
                        item,
                        score: 1.0,
                        matches: [{ indices: [0, value.length], key: String(key) }]
                    });
                    break;
                }
            }
        }

        return results.slice(0, this.config.maxResults ?? 100);
    }
}
```

### 3.3 Rust (メモリ安全な検索インデックス)
```rust
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct InvertedIndex {
    docs: HashMap<usize, String>,
    index: HashMap<String, Vec<usize>>,
}

impl InvertedIndex {
    pub fn new() -> Self {
        InvertedIndex {
            docs: HashMap::new(),
            index: HashMap::new(),
        }
    }

    pub fn add_document(&mut self, doc_id: usize, content: &str) {
        self.docs.insert(doc_id, content.to_string());
        for word in content.split_whitespace() {
            let clean_word = word.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
            if !clean_word.is_empty() {
                self.index.entry(clean_word).or_insert_with(Vec::new).push(doc_id);
            }
        }
    }

    pub fn search(&self, keyword: &str) -> Option<&Vec<usize>> {
        let clean_keyword = keyword.to_lowercase();
        self.index.get(&clean_keyword)
    }
}

fn main() {
    let mut search_db = InvertedIndex::new();
    search_db.add_document(1, "Neovim is fast and efficient");
    search_db.add_document(2, "Rust guarantees memory safety");
    search_db.add_document(3, "Search indexing with Rust in Neovim plugins");

    if let Some(results) = search_db.search("neovim") {
        println!("Found 'neovim' in documents: {:?}", results);
    }
}
```

---

## 4. 置換（`:%s`）テスト用のターゲットリスト

以下のセクションのテキストは、各種置換コマンド（`:s/old/new/g` など）の実験用データです。

### 4.1 変数名の一括置換（CamelCase / snake_case / kebab-case）
* `user_account_id` -> `userAccountId`
* `user_account_name` -> `userAccountName`
* `user_account_email` -> `userAccountEmail`
* `user_account_status` -> `userAccountStatus`
* `user_account_created_at` -> `userAccountCreatedAt`

### 4.2 設定値の置換（`true` / `false` / 数値）
```ini
[server_config]
host = "127.0.0.1"
port = 8080
enable_ssl = false
max_connections = 100
timeout_seconds = 30
debug_mode = false
log_level = "info"
```

### 4.3 ログデータの正規表現抽出・置換
以下の形式のログから IP アドレスやステータスコードを抽出・置換する練習を行えます。

```text
2026-08-12 10:00:01 [INFO] 192.168.1.10 - GET /api/v1/status - 200 OK
2026-08-12 10:00:05 [WARN] 192.168.1.15 - POST /api/v1/login - 401 Unauthorized
2026-08-12 10:00:12 [ERROR] 10.0.0.50 - GET /api/v1/data - 500 Internal Server Error
2026-08-12 10:00:20 [INFO] 192.168.1.10 - PUT /api/v1/user/1 - 200 OK
2026-08-12 10:00:25 [INFO] 172.16.0.8 - DELETE /api/v1/item/99 - 204 No Content
```

---

## 5. まとめとテスト完了確認

Neovim での代表的な検索・置換操作の復習チェックリストです。

- [ ] `/keyword` で「keyword」を順方向検索できるか
- [ ] `?keyword` で「keyword」を逆方向検索できるか
- [ ] 単語上で `*` や `#` を押して、カーソル下の単語を瞬時に検索できるか
- [ ] `:%s/2026/2027/g` で年号の一括置換が行えるか
- [ ] `f(` や `t"` などで改行内の文字移動がスムーズに行えるか
- [ ] 正規表現 `\v` (very magic) を利用した複雑なパターンマッチが機能するか

以上のテキストを用いて、キーボードショートカットや各種プラグイン（`telescope.nvim`, `flash.nvim`, `hlslens` など）の動作検証を行ってください。


end
