"""
Branded HTML & plain-text email templates for KisanRider.

Design principles:
- Green brand identity (#2E7D32 primary, #1B5E20 dark, #E8F5E9 light tint)
- Clean, responsive email layout compatible with all major email clients
- High-contrast, easily readable 4-digit OTP card with monospace font
- Clear 5-minute expiry notice
- Prominent security advisory warning against sharing OTPs
- Multipart fallback providing full plain-text alternative
"""

def render_kisanrider_otp_email(
    otp_code: str,
    title: str,
    subtitle: str,
    instruction: str,
    expiry_minutes: int = 5,
) -> tuple[str, str]:
    """
    Renders both HTML and plain-text versions of a branded KisanRider OTP email.

    Returns:
        (html_content, text_content)
    """
    text_content = (
        f"KisanRider — Farm to Mandi Direct Transport\n"
        f"{'=' * 45}\n\n"
        f"{title}\n"
        f"{subtitle}\n\n"
        f"{instruction}\n\n"
        f"Your Verification Code:  {otp_code}\n\n"
        f"This code will expire in {expiry_minutes} minutes.\n\n"
        f"SECURITY NOTICE: Never share this OTP with anyone. KisanRider staff will never ask for your verification code.\n\n"
        f"If you did not request this code, you can safely ignore this email.\n"
        f"— KisanRider Team\n"
    )

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>
</head>
<body style="margin: 0; padding: 0; background-color: #F4F6F8; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #F4F6F8; padding: 30px 15px;">
    <tr>
      <td align="center">
        <!-- Main Container -->
        <table role="presentation" width="100%" style="max-width: 520px; background-color: #FFFFFF; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 14px rgba(0,0,0,0.06); border: 1px solid #E0E4E8;">
          
          <!-- Header Banner -->
          <tr>
            <td style="background-color: #2E7D32; padding: 28px 24px; text-align: center;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
                <tr>
                  <td align="center">
                    <span style="display: inline-block; font-size: 28px; line-height: 1;">🌾</span>
                    <h1 style="margin: 8px 0 0; color: #FFFFFF; font-size: 24px; font-weight: 700; letter-spacing: 0.5px;">KisanRider</h1>
                    <p style="margin: 4px 0 0; color: #C8E6C9; font-size: 13px; font-weight: 500; letter-spacing: 0.3px;">Farm to Mandi Direct Transport</p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Main Content Card -->
          <tr>
            <td style="padding: 32px 28px 24px;">
              <h2 style="margin: 0 0 8px; color: #1B5E20; font-size: 20px; font-weight: 700; text-align: center;">{title}</h2>
              <p style="margin: 0 0 20px; color: #555555; font-size: 14px; text-align: center; line-height: 1.5;">{instruction}</p>
              
              <!-- OTP Box -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin: 24px 0;">
                <tr>
                  <td align="center">
                    <div style="background-color: #F1F8E9; border: 2px dashed #81C784; border-radius: 10px; padding: 18px 24px; display: inline-block; min-width: 200px;">
                      <span style="font-family: 'Courier New', Courier, monospace; font-size: 38px; font-weight: 800; letter-spacing: 10px; color: #2E7D32; text-indent: 10px; display: block;">{otp_code}</span>
                    </div>
                  </td>
                </tr>
              </table>

              <!-- Expiry Alert -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-bottom: 20px;">
                <tr>
                  <td align="center">
                    <p style="margin: 0; color: #666666; font-size: 13px; line-height: 1.4;">
                      ⏱️ Valid for <strong>{expiry_minutes} minutes</strong>. Do not share this code.
                    </p>
                  </td>
                </tr>
              </table>

              <!-- Security Notice -->
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color: #FFFDE7; border-left: 4px solid #FBC02D; border-radius: 6px; margin-top: 16px;">
                <tr>
                  <td style="padding: 12px 14px;">
                    <p style="margin: 0; color: #5D4037; font-size: 12px; line-height: 1.45;">
                      <strong>Security Notice:</strong> KisanRider employees or riders will never contact you asking for your verification OTP. If you did not make this request, you can safely ignore this message.
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- Footer -->
          <tr>
            <td style="background-color: #FAFAFA; border-top: 1px solid #EEEEEE; padding: 20px 24px; text-align: center;">
              <p style="margin: 0 0 6px; color: #888888; font-size: 12px;">This is an automated notification from KisanRider.</p>
              <p style="margin: 0; color: #AAAAAA; font-size: 11px;">&copy; KisanRider — Connecting Farmers & Mandis Across Karnataka.</p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""

    return html_content, text_content
