module ApplicationHelper
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
