package cmd

import "testing"

func TestParseCRV1(t *testing.T) {
	tests := []struct {
		name    string
		line    string
		wantNil bool
		wantSID string
		wantURL string
	}{
		{
			name:    "aws saml challenge (real management line)",
			line:    `>PASSWORD:Verification Failed: 'Auth' ['CRV1:R:instance-2/7650139661538329560/47a1b00f-b7ed-42b6-a9d9-986a6075a73c:b'Ti9B':https://sso.jumpcloud.com/saml2/awsclientvpn?SAMLRequest=fZLLbtsw']`,
			wantSID: "instance-2/7650139661538329560/47a1b00f-b7ed-42b6-a9d9-986a6075a73c",
			wantURL: "https://sso.jumpcloud.com/saml2/awsclientvpn?SAMLRequest=fZLLbtsw",
		},
		{
			name:    "totp-style challenge from management docs",
			line:    `>PASSWORD:Verification Failed: ['CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:Y3Ix:Please enter token PIN']`,
			wantSID: "Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l",
			wantURL: "Please enter token PIN",
		},
		{
			name:    "no challenge present",
			line:    `>PASSWORD:Verification Failed: 'Auth'`,
			wantNil: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseCRV1(tt.line)
			if tt.wantNil {
				if got != nil {
					t.Fatalf("expected nil, got %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatal("expected a challenge, got nil")
			}
			if got.sid != tt.wantSID {
				t.Errorf("sid:\n got=%q\nwant=%q", got.sid, tt.wantSID)
			}
			if got.url != tt.wantURL {
				t.Errorf("url:\n got=%q\nwant=%q", got.url, tt.wantURL)
			}
		})
	}
}

func TestEscapeMgmt(t *testing.T) {
	in := `CRV1::sid::a"b\c`
	want := `CRV1::sid::a\"b\\c`
	if got := escapeMgmt(in); got != want {
		t.Errorf("got=%q want=%q", got, want)
	}
}
