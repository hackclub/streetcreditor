class ManualOverride < ConfigRecord
  self.table_name = "Manual Overrides"

  TABLE_ID = "tblLiZSA00dJuUTeC"
  FIELD_EMAIL = "fldOXy4Je0R4AXn8Y"
  FIELD_SHIP_DATE = "fldHzr4OaQvUtQs5c"

  field :email, "Email"
  field :ship_date, "Ship Date"
end
