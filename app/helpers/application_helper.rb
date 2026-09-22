module ApplicationHelper
  def signal_symbol(signal)
    if signal.kind == 'reversal'
      return signal.details['direction'] == 'up' ? ['⤴', 'price-up', 'Откуп после снижения'] : ['⤵', 'price-down', 'Продажи после роста']
    end
    return ["⌁", nil, nil] unless signal.kind == "volume"
    case signal.price_direction
    when "up" then ["↗", "price-up", "Цена выросла за аномальную минуту или эпизод"]
    when "down" then ["↘", "price-down", "Цена снизилась за аномальную минуту или эпизод"]
    else ["→", "price-flat", "Направление цены не определено"]
    end
  end

  def signed_percent(value)
    "#{value.positive? ? '+' : ''}#{number_with_precision(value, precision: 2)}%"
  end

  def signal_price(value)
    number_with_precision(value, precision: 1, strip_insignificant_zeros: true, separator: ",", delimiter: " ")
  end

  def level_status_label(status)
    { "candidate" => "Предварительная", "confirmed" => "Подтверждённая", "broken" => "Пробой: наблюдаем", "archived" => "Архив" }.fetch(status, status)
  end

  def trend_description(context)
    return "Недостаточно истории для EMA" if context.blank? || context["close"].nil?
    values = (context["ema"] || {}).filter_map do |period, value|
      next if value.nil?
      relation = context["close"].to_f >= value ? "выше" : "ниже"
      "закрытие #{relation} EMA#{period} (#{number_with_precision(value, precision: 2)})"
    end
    values.any? ? values.join(" · ") : "Недостаточно истории для EMA"
  end
end
