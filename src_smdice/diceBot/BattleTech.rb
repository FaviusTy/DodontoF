#--*-coding:utf-8-*--

class BattleTech < DiceBot
  
  def initialize
    super
    
    # @sendMode = @@DEFAULT_SEND_MODE #(0=結果のみ,1=0+式,2=1+ダイス個別)
    # @sortType = 0;      #ソート設定(1 = ?, 2 = ??, 3 = 1&2　各値の意味が不明です懼�ｦ）
    # @sameDiceRerollCount = 0;     #ゾロ目で振り足し(0=無し, 1=全部同じ目, 2=ダイスのうち2個以上同じ目)
    # @sameDiceRerollType = 0;   #ゾロ目で振り足しのロール種別(0=判定のみ, 1=ダメージのみ, 2=両方)
    # @d66Type = 0;        #d66の差し替え
    # @isPrintMaxDice = false;      #最大値表示
    # @upplerRollThreshold = 0;      #上方無限
    # @unlimitedRollDiceType = 0;    #無限ロールのダイス
    # @rerollNumber = 0;      #振り足しする条件
    # @defaultSuccessTarget = "";      #目標値が空欄の時の目標値
    # @rerollLimitCount = 0;    #振り足し回数上限
    # @fractionType = "omit";     #端数の処理 ("omit"=切り捨て, "roundUp"=切り上げ, "roundOff"=四捨五入)
  end
  
  
  def prefixs
    ['\d*SRM\d+.+', '\d*LRM\d+.+', '\d*BT.+', 'CT', 'DW', 'CD\d+']
  end
  
  def gameName
    'バトルテック'
  end
  
  def gameType
    "BattleTech"
  end
  
  def getHelpMessage
    return <<MESSAGETEXT
・判定方法
　(回数)BT(ダメージ)(部位)+(基本値)>=(目標値)
　回数は省略時 1固定。
　部位はC（正面）R（右）、L（左）。省略時はC（正面）固定
　U（上半身）、L（下半身）を組み合わせ CU/RU/LU/CL/RL/LLも指定可能
　例）BT3+2>=4
　　正面からダメージ3の攻撃を技能ベース2目標値4で1回判定
　例）2BT3RL+5>=8
　　右下半身にダメージ3の攻撃を技能ベース5目標値8で2回判定
　ミサイルによるダメージは BT(ダメージ)の変わりに SRM2/4/6, LRM5/10/15/20を指定
　例）3SRM6LU+5>=8
　　左上半身にSRM6連を技能ベース5目標値8で3回判定
・CT：致命的命中表
・DW：転倒後の向き表
・CDx：メック戦士意識維持表。ダメージ値xで判定　例）CD3
MESSAGETEXT
  end
  
  def changeText(string)
    string.sub(/PPC/, 'BT10')
  end
  
  def undefCommandResult
    '1'
  end
  
  def dice_command(string, nick_e)
    secret_flg = false
    
    return '1', secret_flg unless( /(^|\s)(S)?(#{prefixs.join('|')})(\s|$)/i =~ string )
    
    secretMarker = $2
    command = $3
    
    output_msg = executeCommand(command)
    output_msg = '1' if( output_msg.nil? or output_msg.empty? )
    
    output_msg = "#{nick_e}：#{output_msg}" if(output_msg != '1')
    
    if( secretMarker )   # 隠しロール
      secret_flg = true if(output_msg != '1')
    end
    
    return output_msg, secret_flg
  end
  
  def executeCommand(command)
    result = nil
    begin
      result = executeCommandCatched(command)
    rescue => e
      debug("executeCommand exception", e.to_s, $@.join("\n"));
    end
    
    return result
  end
  
  def executeCommandCatched(command)
    
    count = 1
    if( /^(\d+)(.+)/ === command )
      count = $1.to_i
      command = $2
    end
    
    debug('executeCommandCatched count', count)
    debug('executeCommandCatched command', command)
    
    case command
    when /^CT$/
      criticalDice, criticalText = getCriticalResult()
      return "#{criticalDice} ＞ #{criticalText}"
    when /^DW$/
      return getDownResult()
    when /^CD(\d+)$/
      damage = $1.to_i
      return getCheckDieResult(damage)
    when /^((S|L)RM\d+)(.+)/
      tail = $3
      type = $1
      damageFunc = lambda{getXrmDamage(type)}
      return getHitResult(count, damageFunc, tail)
    when /^BT(\d+)(.+)/
      debug('BT pattern')
      tail = $2
      damageValue = $1.to_i
      damageFunc = lambda{ damageValue }
      return getHitResult(count, damageFunc, tail)
    end
    
    return nil
  end
  
  def getXrmDamage(type)
    table, isLrm = getXrmDamageTable(type)
    
    table = table.collect{|i|i*2} unless(isLrm)
    
    damage, dice = get_table_by_2d6(table)
    return damage, dice, isLrm
  end
  
  def getXrmDamageTable(type)
    # table, isLrm
    case type
    when /^SRM2$/i
      [[1,	1,	1,	1,	1,	1,	2,	2,	2,	2,	2], false]
    when /^SRM4$/i
      [[1,	2,	2,	2,	2,	3,	3,	3,	3,	4,	4], false]
    when /^SRM6$/i
      [[2,	2,	3,	3,	4,	4,	4,	5,	5,	6,	6], false]
    when /^LRM5$/i
      [[1,	2,	2,	3,	3,	3,	3,	4,	4,	5,	5], true]
    when /^LRM10$/i
      [[3,	3,	4,	6,	6,	6,	6,	8,	8,	10,	10], true]
    when /^LRM15$/i
      [[5,	5,	6,	9,	9,	9,	9,	12,	12,	15,	15], true]
    when /^LRM20$/i
      [[6,	6,	9,	12,	12,	12,	12,	16,	16,	20,	20], true]
    else
      raise "unknown XRM type:#{type}"
    end
  end
  
  
  @@lrmLimit = 5
  
  
  def getHitResult(count, damageFunc, tail)
    
    return nil unless( /(\w*)(\+\d+)?>=(\d+)/ === tail )
    side = $1
    baseString = $2
    target = $3.to_i
    base = getBaseValue(baseString)
    debug("side, base, target", side, base, target)
    
    partTable = getHitPart(side)
    
    resultTexts = []
    damages = {}
    hitCount = 0
    
    count.times do
      isHit, hitResult = getHitText(base, target)
      resultTexts << hitResult
      
      next unless( isHit )
      hitCount += 1
      
      damages, damageText = getDamages(damageFunc, partTable, damages)
      resultTexts.last << damageText
    end
    
    totalResultText = resultTexts.join("\n")
    
    if( totalResultText.length >= $SEND_STR_MAX )
      totalResultText = "..."
    end
    
    totalResultText << "\n ＞ #{hitCount}回命中"
    totalResultText << " 命中箇所：" + getTotalDamage(damages) if( hitCount > 0 )
    
    return totalResultText
  end
  
  
  def getBaseValue(baseString)
    base = 0
    return base if( baseString.nil? )
    
    base = parren_killer("(" + baseString + ")").to_i
    return base
  end
  
  def getHitPart(side)
    case side
    when /^L$/i
      ['左胴＠', '左脚', '左腕', '左腕', '左脚', '左胴', '胴中央', '右胴', '右腕', '右脚', '頭']
    when /^C$/i, '', nil
      ['胴中央＠', '右腕', '右腕', '右脚', '右胴', '胴中央', '左胴', '左脚', '左腕', '左腕', '頭']
    when /^R$/i
      ['右胴＠', '右脚', '右腕', '右腕', '右脚', '右胴', '胴中央', '左胴', '左腕', '左脚', '頭']
      
    when /^LU$/i
      ['左胴', '左胴', '胴中央', '左腕', '左腕', '頭']
    when /^CU$/i
      ['左腕', '左胴', '胴中央', '右胴', '右腕', '頭']
    when /^RU$/i
      ['右胴', '右胴', '胴中央', '右腕', '右腕', '頭']
      
    when /^LL$/i
      ['左脚', '左脚', '左脚', '左脚', '左脚', '左脚']
    when /^CL$/i
      ['右脚', '右脚', '右脚', '左脚', '左脚', '左脚']
    when /^RL$/i
      ['右脚', '右脚', '右脚', '右脚', '右脚', '右脚']
    else
      raise "unknown hit part side :#{side}"
    end
  end
  
  
  def getHitText(base, target)
    dice1, = roll(1, 6)
    dice2, = roll(1, 6)
    total = dice1 + dice2 + base
    isHit = ( total >= target )
    baseString = (base > 0 ? "+#{base}" : "")
    
    result = "#{total}[#{dice1},#{dice2}#{baseString}]>=#{target} ＞ "
    
    if( isHit )
      result += "命中 ＞ "
    else
      result += "外れ"
    end
    
    return isHit, result
  end
  
  
  def getDamages(damageFunc, partTable, damages)
    resultText = ''
    damage, dice, isLrm = damageFunc.call()
    
    damagePartCount = 1
    if( isLrm )
      damagePartCount = (1.0 * damage / @@lrmLimit).ceil
      resultText << "[#{dice}] #{damage}点"
    end
    
    damagePartCount.times do |damageIndex|
      currentDamage, damageText = getDamageInfo(dice, damage, isLrm, damageIndex)
      
      text, part, criticalText = getHitResultOne(damageText, partTable)
      resultText << " " if( isLrm )
      resultText << text
      
      if( damages[part].nil? )
        damages[part] = {
          :partDamages => [],
          :criticals => [],
        }
      end
      
      damages[part][:partDamages] << currentDamage
      damages[part][:criticals] << criticalText unless( criticalText.empty? )
    end
    
    return damages, resultText
  end
  
  
  def getDamageInfo(dice, damage, isLrm, index)
    return damage, "#{damage}" if( dice.nil? )
    return damage, "[#{dice}] #{damage}" unless( isLrm )
    
    currentDamage = damage - (@@lrmLimit * index)
    if( currentDamage > @@lrmLimit )
      currentDamage = @@lrmLimit
    end
    
    return currentDamage, "#{currentDamage}"
  end
  
  
  def getTotalDamage(damages)
    parts = ['頭',
             '胴中央',
             '右胴',
             '左胴', 
             '右脚',
             '左脚',
             '右腕',
             '左腕',]
    
    allDamage = 0
    damageTexts = []
    parts.each do |part|
      damageInfo = damages.delete(part)
      next if( damageInfo.nil? )
      
      damage = damageInfo[:partDamages].inject(0){|sum, i| sum + i}
      allDamage += damage
      damageCount = damageInfo[:partDamages].size
      criticals = damageInfo[:criticals]
      
      text = ""
      text << "#{part}(#{damageCount}回) #{damage}点"
      text << " #{criticals.join(' ')}" unless( criticals.empty? )
      
      damageTexts << text
    end
    
    if( damages.length > 0 )
      raise "damages rest!! #{damages.inspect()}"
    end
    
    result = damageTexts.join(" ／ ")
    result += " ＞ 合計ダメージ #{allDamage}点"
    
    return result
  end
  
  
  def getHitResultOne(damageText, partTable)
    part, value = getPart(partTable)
    
    result = ""
    result << "[#{value}] #{part.gsub(/＠/, '（致命的命中）')} #{damageText}点"
    debug('result', result)
    
    index = part.index('＠')
    isCritical = (not index.nil?)
    debug("isCritical", isCritical)
    
    part = part.gsub(/＠/, '')
    
    criticalText = ''
    if( isCritical )
      criticalDice, criticalText = getCriticalResult()
      result << " ＞ [#{criticalDice}] #{criticalText}"
    end
    
    criticalText = '' if( criticalText == @@noCritical )
    
    return result, part, criticalText
  end
  
  def getPart(partTable)
    diceCount = 2
    if( partTable.length == 6 )
      diceCount = 1
    end
    
    part, value = get_table_by_nD6(partTable, diceCount)
  end
  
  @@noCritical = '致命的命中はなかった'
  
  def getCriticalResult()
    table = [[ 7, @@noCritical],
             [ 9, '1箇所の致命的命中'],
             [11, '2箇所の致命的命中'],
             [12, 'その部位が吹き飛ぶ（腕、脚、頭）または3箇所の致命的命中（胴）'],
            ]
    
    dice, = roll(2, 6)
    result = get_table_by_number(dice, table, '')
    
    return dice, result
  end
  
  
  def getDownResult()
    table = ['同じ（前面から転倒） 正面／背面',
             '1ヘクスサイド右（側面から転倒） 右側面',
             '2ヘクスサイド右（側面から転倒） 右側面',
             '180度逆（背面から転倒） 正面／背面',
             '2ヘクスサイド左（側面から転倒） 左側面',
             '1ヘクスサイド左（側面から転倒） 左側面',]
    result, dice = get_table_by_1d6(table)
    
    return "#{dice} ＞ #{result}"
  end
  
  def getCheckDieResult(damage)
    if( damage >= 6 )
      return "死亡"
    end
    
    table = [[1,	3],
             [2,	5],
             [3,	7],
             [4,	10],
             [5,	11]]
    
    target = get_table_by_number(damage, table, nil)
    
    dice1, = roll(1, 6)
    dice2, = roll(1, 6)
    total = dice1 + dice2
    result = ( total >= target ) ? "成功" : "失敗"
    text = "#{total}[#{dice1},#{dice2}]>=#{target} ＞ #{result}"
    
    return text
  end
  
  #以下のメソッドはテーブルの参照用に便利
  #get_table_by_2d6(table)
  #get_table_by_1d6(table)
  #get_table_by_nD6(table, 1)
  #get_table_by_nD6(table, count)
  #get_table_by_1d3(table)
  #get_table_by_number(index, table)
  #get_table_by_d66(table)
  
  #ダイス目が知りたくなったら getDiceList を呼び出すこと(diceBot.rbにて定義)
end
