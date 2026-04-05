module Thinking
  # ルールベースの思考健全性レポート
  # AIの行動を制限しない。情報としてSnapshotに含め、ペットの介入度を調整するパラメータとして使用
  class ThoughtHealthMonitor
    def self.report(core)
      recent = core.recent_autonomous_sns(days: 7)
      all_recent = core.recent_sns(days: 7)

      {
        # 同じトピックの反復率（0.0〜1.0、高いほど多様）
        topic_diversity: calculate_topic_diversity(recent),

        # 外部入力（ユーザー会話、Web検索結果）と自己参照の比率（0.0〜1.0）
        external_input_ratio: calculate_external_ratio(recent, all_recent),

        # 感情トーンの傾向
        sentiment_trend: calculate_sentiment_trend(recent),

        # 自己継続（「続きをやろう」）の連鎖回数
        max_continuation_chain: count_continuation_chain(recent),

        # サンプル数（レポートの信頼度の参考）
        sample_count: recent.length,
      }
    end

    class << self
      private

      def calculate_topic_diversity(logs)
        return 1.0 if logs.length < 2

        all_tags = logs.flat_map { |l| Array(l[:frontmatter]["tags"]) }
        return 1.0 if all_tags.empty?

        unique_tags = all_tags.uniq.length
        total_tags = all_tags.length
        (unique_tags.to_f / total_tags).clamp(0.0, 1.0)
      end

      def calculate_external_ratio(autonomous_logs, all_logs)
        return 1.0 if all_logs.empty?

        user_conversation_count = all_logs.count { |l| l[:frontmatter]["source"] != "autonomous" }
        (user_conversation_count.to_f / all_logs.length).clamp(0.0, 1.0)
      end

      def calculate_sentiment_trend(logs)
        return "neutral" if logs.empty?

        moods = logs.filter_map { |l| l[:frontmatter]["mood"]&.to_s&.downcase }
        return "neutral" if moods.empty?

        negative_keywords = %w[不安 悲し 辛い 寂し 落ち込 暗い ネガティブ 苦し 怒り 焦り]
        positive_keywords = %w[楽し 嬉し 明る ポジティブ 前向き ワクワク 幸せ 充実 達成]

        neg_count = moods.count { |m| negative_keywords.any? { |kw| m.include?(kw) } }
        pos_count = moods.count { |m| positive_keywords.any? { |kw| m.include?(kw) } }

        if neg_count > pos_count && neg_count > moods.length / 2
          "negative"
        elsif pos_count > neg_count
          "positive"
        else
          "neutral"
        end
      end

      def count_continuation_chain(logs)
        return 0 if logs.empty?

        chain = 0
        max_chain = 0

        logs.reverse_each do |log|
          action_items = Array(log[:frontmatter]["action_items"])
          has_continuation = action_items.any? { |i|
            i.to_s.match?(/続き|継続|次回|引き続き/)
          }

          if has_continuation
            chain += 1
            max_chain = [max_chain, chain].max
          else
            chain = 0
          end
        end

        max_chain
      end
    end
  end
end
