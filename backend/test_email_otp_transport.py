import config
import otp_service


class _DummyResp:
    def __init__(self, status_code: int = 201, text: str = '{"messageId":"m-1"}'):
        self.status_code = status_code
        self.text = text


def test_brevo_https_dispatch(monkeypatch):
    captured = {}

    def fake_post(url, headers=None, json=None, timeout=None, **kwargs):
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json
        return _DummyResp(201)

    monkeypatch.setattr(config, "ENABLE_REAL_EMAIL_OTP", True)
    monkeypatch.setattr(config, "BREVO_API_KEY", "xkeysib-test-key")
    monkeypatch.setattr(config, "BREVO_SENDER_EMAIL", None)
    monkeypatch.setattr(config, "SMTP_EMAIL", "sender@gmail.com")
    monkeypatch.setattr(config, "EMAIL_WEBHOOK_URL", None)
    monkeypatch.setattr(otp_service.httpx, "post", fake_post)

    res = otp_service.issue_and_send_email_otp("farmer@example.com")
    assert res["sent"] is True
    assert res["bypass"] is False
    assert captured["url"] == "https://api.brevo.com/v3/smtp/email"
    assert captured["headers"]["api-key"] == "xkeysib-test-key"
    assert captured["json"]["sender"]["email"] == "sender@gmail.com"
    assert captured["json"]["to"] == [{"email": "farmer@example.com"}]
    assert res["code"] in captured["json"]["textContent"]
    assert otp_service.verify_email_otp_code("farmer@example.com", res["code"]) is True


def test_webhook_https_dispatch(monkeypatch):
    captured = {}

    def fake_post(url, json=None, follow_redirects=False, timeout=None, **kwargs):
        captured["url"] = url
        captured["json"] = json
        captured["follow_redirects"] = follow_redirects
        return _DummyResp(200, '{"ok":true}')

    monkeypatch.setattr(config, "ENABLE_REAL_EMAIL_OTP", True)
    monkeypatch.setattr(config, "BREVO_API_KEY", None)
    monkeypatch.setattr(config, "EMAIL_WEBHOOK_URL", "https://script.google.com/macros/s/demo/exec")
    monkeypatch.setattr(otp_service.httpx, "post", fake_post)

    res = otp_service.issue_and_send_password_reset_otp("rider@example.com")
    assert res["sent"] is True
    assert captured["url"] == "https://script.google.com/macros/s/demo/exec"
    assert captured["follow_redirects"] is True
    assert captured["json"]["to"] == "rider@example.com"
    assert res["code"] in captured["json"]["text"]
    assert otp_service.verify_password_reset_otp_code("rider@example.com", res["code"]) is True


def test_smtp_fallback_when_no_https_transport(monkeypatch):
    called = {"login": None, "sent": False}

    class FakeSmtp:
        def __init__(self, host, port, timeout=None):
            called["host"] = host
            called["port"] = port

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def login(self, user, password):
            called["login"] = (user, password)

        def send_message(self, msg):
            called["sent"] = True

    monkeypatch.setattr(config, "ENABLE_REAL_EMAIL_OTP", True)
    monkeypatch.setattr(config, "BREVO_API_KEY", None)
    monkeypatch.setattr(config, "EMAIL_WEBHOOK_URL", None)
    monkeypatch.setattr(config, "SMTP_EMAIL", "local@gmail.com")
    monkeypatch.setattr(config, "SMTP_PASSWORD", "app-pass")
    monkeypatch.setattr(config, "SMTP_SERVER", "smtp.gmail.com")
    monkeypatch.setattr(otp_service.smtplib, "SMTP_SSL", FakeSmtp)

    res = otp_service.issue_and_send_email_otp("user@example.com")
    assert res["sent"] is True
    assert called["host"] == "smtp.gmail.com"
    assert called["port"] == 465
    assert called["login"] == ("local@gmail.com", "app-pass")
    assert called["sent"] is True
