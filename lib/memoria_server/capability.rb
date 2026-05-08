module MemoriaServer
  # クライアントが宣言する出力 capability の定義。
  #
  # 各 capability は以下を持つ：
  #   - name: シンボル識別子（例 :emotion）
  #   - value_format: LLM への形式説明（例 '"happy" | "sad" | ...'）
  #   - value_extractor: LLM が返した JSON Hash から自分の値を取り出す proc
  #
  # クライアントはリクエストの `x_memoria.wants` に文字列で capability 名を列挙する。
  # 例: `{"x_memoria": {"wants": ["emotion", "servo"]}}`
  class Capability
    attr_reader :name, :value_format

    def initialize(name:, value_format:, value_extractor:)
      @name = name.to_sym
      @value_format = value_format
      @value_extractor = value_extractor
    end

    # @param json_obj [Hash] LLM が `<x_memoria>{...}</x_memoria>` 内に返した JSON Hash
    # @return [Object, nil] 該当値（不正値の場合は nil）
    def parse_value(json_obj)
      return nil unless json_obj.is_a?(Hash)
      @value_extractor.call(json_obj)
    end

    # --- Registry ---

    @registry = {}

    class << self
      def register(capability)
        @registry[capability.name] = capability
      end

      def find(name)
        @registry[name.to_s.to_sym]
      end

      def all
        @registry.values
      end

      # capability 名のリスト（文字列 or Symbol）から Capability 配列を返す。未登録名は黙って無視。
      def resolve_many(names)
        Array(names).map { |n| find(n) }.compact
      end
    end
  end
end
