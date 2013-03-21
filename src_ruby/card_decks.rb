# encoding:utf-8

class CardDecks

  def self.infos
    @infos ||=
        [

            { :type  => 'trump_swf',
              :title => 'トランプ',
              :file  => 'cards/trump_swf.txt',
            },


            { :type  => 'randomDungeonTrump',
              :title => 'ランダムダンジョン・トランプ',
              :file  => 'cards/trump_swf.txt',
            },


            { :type  => 'witchQuestWitchTaro',
              :title => 'ウィッチクエスト：ウィッチ・タロー',
              :file  => 'cards/witchQuestWitchTaro.txt',
            },


            { :type  => 'witchQuestStructureCard',
              :title => 'ウィッチクエスト：ストラクチャーカード(テキストのみ)',
              :file  => 'cards/witchQuestStructureCard.txt',
            },

            { :type  => 'torg',
              :title => 'TORG：ドラマデッキ',
              :file  => 'cards/torg.txt',
            },

            { :type  => 'nova',
              :title => 'トーキョーN◎VA：ニューロデッキ',
              :file  => 'cards/nova.txt',
            },

            { :type  => 'shinnen',
              :title => '深淵：運命カード',
              :file  => 'cards/shinnen.txt',
            },

            { :type  => 'shinnen_red',
              :title => '深淵：運命カード(夢魔の占い札対応版)',
              :file  => 'cards/shinnen_red.txt',
            },

            { :type  => 'bladeOfArcana',
              :title => 'ブレイド・オブ・アルカナ：タロット',
              :file  => 'cards/bladeOfArcana.txt',
            },

            { :type  => 'gunMetalBlaze',
              :title => 'ガンメタル・ブレイズ：シチュエーションカード',
              :file  => 'cards/gunMetalBlaze.txt',
            },

            { :type  => 'gunMetalBlazeLoversStreet',
              :title => 'ガンメタル・ブレイズ：シチュエーションカード(ラバーズストリート対応版)',
              :file  => 'cards/gunMetalBlazeLoversStreet.txt',
            },

            { :type  => 'tatoono',
              :title => 'ローズ・トゥ・ロード：タトゥーノ',
              :file  => 'cards/tatoono.txt',
            },

            { :type  => 'farRoadsToLoad_chien:hikari',
              :title => 'ファー・ローズ・トゥ・ロード：地縁カード:光',
              :file  => 'cards/farRoadsToLoad/chien_hikari.txt',
            },

            { :type  => 'farRoadsToLoad_chien:ishi',
              :title => '石',
              :file  => 'cards/farRoadsToLoad/chien_ishi.txt',
            },

            { :type  => 'farRoadsToLoad_chien:koori',
              :title => '氷',
              :file  => 'cards/farRoadsToLoad/chien_koori.txt',
            },

            { :type  => 'farRoadsToLoad_chien:mori',
              :title => '森',
              :file  => 'cards/farRoadsToLoad/chien_mori.txt',
            },

            { :type  => 'farRoadsToLoad_chien:umi',
              :title => '海',
              :file  => 'cards/farRoadsToLoad/chien_umi.txt',
            },

            { :type  => 'farRoadsToLoad_chien:yami',
              :title => '闇',
              :file  => 'cards/farRoadsToLoad/chien_yami.txt',
            },

            { :type  => 'farRoadsToLoad_reien:chi',
              :title => 'ファー・ローズ・トゥ・ロード：霊縁カード:地',
              :file  => 'cards/farRoadsToLoad/reien_chi.txt',
            },

            { :type  => 'farRoadsToLoad_reien:hi',
              :title => '火',
              :file  => 'cards/farRoadsToLoad/reien_hi.txt',
            },

            { :type  => 'farRoadsToLoad_reien:kaze',
              :title => '風',
              :file  => 'cards/farRoadsToLoad/reien_kaze.txt',
            },

            { :type  => 'farRoadsToLoad_reien:mizu',
              :title => '水',
              :file  => 'cards/farRoadsToLoad/reien_mizu.txt',
            },

            { :type  => 'farRoadsToLoad_reien:uta',
              :title => '歌',
              :file  => 'cards/farRoadsToLoad/reien_uta.txt',
            },

            { :type  => 'shanhaitaimakou',
              :title => '上海退魔行：陰陽カード',
              :file  => 'cards/shanhaitaimakou.txt',
            },

            { :type  => 'actCard',
              :title => 'マスカレイド・スタイル：アクト・カード',
              :file  => 'cards/actCard.txt',
            },

            { :type  => 'ItrasBy_ChanceCard',
              :title => 'Itras By：チャンスカード',
              :file  => 'cards/ItrasBy_ChanceCard.txt',
            },

            { :type  => 'ItrasBy_ResolutionCard',
              :title => 'Itras By：解決カード',
              :file  => 'cards/ItrasBy_ResolutionCard.txt',
            },


        ]
  end

  def self.collect_display_infos
    @infos.collect do |info|
      { :type  => info[:type],
        :title => info[:title],
      }
    end
  end

  def self.file_name(type)
    @infos.find { |deck| deck[:type] == type }[:file]
  end

  def self.title_name(type)
    @infos.find { |deck| deck[:type] == type }[:title]
  end

end
