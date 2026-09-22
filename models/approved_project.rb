class ApprovedProject < ShipsRecord
  self.table_name = "Approved Projects"

  # ids for the airtable webhooks API, which speaks ids not names
  TABLE_ID = "tblzWWGUYHVH7Zyqf"
  FIELD_EMAIL = "fldmqHE7RIvjvglfX"
  FIELD_APPROVED_AT = "fldB6hzaH7SIz9CQi"

  field :email, "Email"
  field :email_normalized, "Email - Trimmed & Lowercased", readonly: true
  field :approved_at, "Approved At"
  field :first_name, "First Name"
  field :last_name, "Last Name"
end
