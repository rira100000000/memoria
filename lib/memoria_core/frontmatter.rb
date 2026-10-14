require "yaml"

module MemoriaCore
  # YAML frontmatter の解析・生成ユーティリティ
  module Frontmatter
    module_function

    # マークダウンファイルからfrontmatterとbodyを分離して返す
    # @return [Hash, String] frontmatter (Hash or nil), body (String)
    def parse(content)
      return [nil, content.to_s] if content.nil? || content.empty?

      match = content.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)/m)
      return [nil, content] unless match

      fm = begin
        load_yaml(match[1]) || {}
      rescue Psych::SyntaxError
        nil
      end
      [fm, match[2].to_s]
    end

    # 日時（例: "2026-10-14 18:30:08"）は Time にせず、書かれた文字列のまま返す。
    # YAML は時差のない日時を UTC として読むため、Time にしてから書き戻すと日本時間との差の分だけずれていく。
    # 日付だけ（"2026-10-14"）は Date のまま。
    class StringTimeScanner < Psych::ScalarScanner
      def tokenize(string)
        return string if string.match?(TIME)

        super
      end
    end

    def load_yaml(yaml)
      class_loader = Psych::ClassLoader::Restricted.new(["Date"], [])
      scanner = StringTimeScanner.new(class_loader)
      Psych::Visitors::NoAliasRuby.new(scanner, class_loader).accept(Psych.parse(yaml))
    end

    # frontmatter Hash と body 文字列からマークダウンを組み立てる
    def build(frontmatter, body)
      yaml = frontmatter.to_yaml.sub(/\A---\n/, "")
      "---\n#{yaml}---\n\n#{body}"
    end
  end
end
