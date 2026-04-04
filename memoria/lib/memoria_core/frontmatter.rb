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
        YAML.safe_load(match[1], permitted_classes: [Date, Time]) || {}
      rescue Psych::SyntaxError
        nil
      end
      [fm, match[2].to_s]
    end

    # frontmatter Hash と body 文字列からマークダウンを組み立てる
    def build(frontmatter, body)
      yaml = frontmatter.to_yaml.sub(/\A---\n/, "")
      "---\n#{yaml}---\n\n#{body}"
    end
  end
end
