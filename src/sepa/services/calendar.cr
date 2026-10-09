# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Jours ouvrés TARGET, ceux du règlement des virements et prélèvements
  # SEPA : du lundi au vendredi, hors 1er janvier, Vendredi saint, lundi de
  # Pâques, 1er mai, 25 et 26 décembre (D-SEPA-008). Interne.
  module Calendar
    def self.business_day?(date : Time) : Bool
      return false if date.saturday? || date.sunday?
      !holidays(date.year).includes?({date.month, date.day})
    end

    # Premier jour ouvré à partir de `date` (compris).
    def self.next_business_day(date : Time) : Time
      day = date.at_beginning_of_day
      until business_day?(day)
        day += 1.day
      end
      day
    end

    # Fériés TARGET de l'année, en (mois, jour).
    def self.holidays(year : Int32) : Array({Int32, Int32})
      easter = easter_sunday(year)
      friday = easter - 2.days
      monday = easter + 1.day
      [{1, 1}, {friday.month, friday.day}, {monday.month, monday.day}, {5, 1}, {12, 25}, {12, 26}]
    end

    # Dimanche de Pâques (calendrier grégorien, algorithme de Meeus).
    def self.easter_sunday(year : Int32) : Time
      a = year % 19
      b = year // 100
      c = year % 100
      d = b // 4
      e = b % 4
      f = (b + 8) // 25
      g = (b - f + 1) // 3
      h = (19 * a + b - d - g + 15) % 30
      i = c // 4
      k = c % 4
      l = (32 + 2 * e + 2 * i - h - k) % 7
      m = (a + 11 * h + 22 * l) // 451
      month = (h + l - 7 * m + 114) // 31
      day = ((h + l - 7 * m + 114) % 31) + 1
      Time.utc(year, month, day)
    end
  end
end
