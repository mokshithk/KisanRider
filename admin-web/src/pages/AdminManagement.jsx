import React, { useState, useEffect } from 'react';
import {
  ShieldCheck,
  UserPlus,
  Mail,
  Copy,
  Check,
  RefreshCw,
  AlertCircle,
  Terminal,
  Clock,
  Send,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';

export default function AdminManagement() {
  const [admins, setAdmins] = useState([]);
  const [invitations, setInvitations] = useState([]);
  const [loading, setLoading] = useState(true);

  // Invite Modal
  const [isInviteOpen, setIsInviteOpen] = useState(false);
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [inviteLoading, setInviteLoading] = useState(false);
  const [inviteError, setInviteError] = useState('');
  const [inviteResult, setInviteResult] = useState(null);
  const [copied, setCopied] = useState(false);

  // Action feedback
  const [toastMessage, setToastMessage] = useState('');

  const fetchAdmins = async () => {
    setLoading(true);
    try {
      const res = await adminService.getAdmins();
      setAdmins(res.admins || []);
      setInvitations(res.pending_invitations || []);
    } catch (err) {
      console.error('Failed to fetch admin users:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchAdmins();
  }, []);

  const handleInviteSubmit = async (e) => {
    e.preventDefault();
    if (!fullName.trim() || !email.trim()) {
      setInviteError('Please provide both administrator name and valid email.');
      return;
    }

    setInviteLoading(true);
    setInviteError('');
    try {
      const res = await adminService.inviteAdmin(email.trim(), fullName.trim());
      setInviteResult(res);
      fetchAdmins();
      setToastMessage(`Invitation created for ${email}.`);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to invite admin:', err);
      const detail = err.response?.data?.detail || 'Failed to generate admin invitation.';
      setInviteError(detail);
    } finally {
      setInviteLoading(false);
    }
  };

  const handleResend = async (invitationId, recipientEmail) => {
    try {
      const res = await adminService.resendInvite(invitationId);
      setToastMessage(`Invitation renewed for ${recipientEmail}.`);
      fetchAdmins();
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to resend invitation:', err);
      alert('Failed to renew invitation.');
    }
  };

  const copyToClipboard = (text) => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const adminColumns = [
    {
      header: 'Administrator Name',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.full_name}</span>
          <span className="text-xs text-text-secondary">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'System Role',
      render: () => (
        <span className="text-xs font-semibold px-2 py-0.5 rounded bg-lime-muted text-forest border border-lime-accent/40">
          ADMIN
        </span>
      ),
    },
    {
      header: 'Status',
      accessor: 'is_active',
      render: (row) => <Badge status={row.is_active ? 'ACTIVE' : 'SUSPENDED'} />,
    },
    {
      header: 'Created On',
      accessor: 'created_at',
      render: (row) => (row.created_at ? new Date(row.created_at).toLocaleDateString() : '-'),
    },
  ];

  const inviteColumns = [
    {
      header: 'Invited Admin',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.full_name}</span>
          <span className="text-xs text-text-secondary">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'Invitation Sent',
      accessor: 'created_at',
      render: (row) => (row.created_at ? new Date(row.created_at).toLocaleString() : '-'),
    },
    {
      header: 'Expires At',
      accessor: 'expires_at',
      render: (row) => (
        <div className="flex items-center space-x-1.5 text-xs text-amber-800">
          <Clock className="w-3.5 h-3.5 text-amber-600" />
          <span>{row.expires_at ? new Date(row.expires_at).toLocaleString() : '-'}</span>
        </div>
      ),
    },
    {
      header: 'Status',
      render: () => <Badge status="PENDING" text="Pending Acceptance" />,
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <button
          onClick={() => handleResend(row.id, row.email)}
          className="text-xs text-forest hover:text-forest-light font-medium px-2.5 py-1 rounded border border-surface-border bg-white hover:bg-surface-subtle transition-colors"
          title="Resend invitation with fresh 24h token"
        >
          Resend Invite
        </button>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      {/* Information Header & Bootstrap Instructions */}
      <div className="p-4 bg-white rounded-lg border border-surface-border text-xs text-text-secondary space-y-2 shadow-xs">
        <div className="flex items-center space-x-2 text-forest font-bold">
          <ShieldCheck className="w-4 h-4 text-forest" />
          <span className="text-text-primary text-sm">Role-Based Administrator Governance</span>
        </div>
        <p className="leading-relaxed">
          KisanRider maintains strict equality among administrators with no artificial Super Admin
          hierarchy. Every authenticated ADMIN can invite new staff members via single-use
          cryptographic tokens. Public registration is permanently locked to FARMER and RIDER roles.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Action Bar */}
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-base font-bold text-text-primary">Active Administrators</h3>
          <p className="text-xs text-text-secondary">Personnel with full platform management authorization</p>
        </div>
        <button
          onClick={() => {
            setIsInviteOpen(true);
            setFullName('');
            setEmail('');
            setInviteError('');
            setInviteResult(null);
          }}
          className="inline-flex items-center space-x-2 px-3.5 py-2 rounded-lg text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-colors shadow-xs"
        >
          <UserPlus className="w-3.5 h-3.5 text-lime-accent" />
          <span>Invite New Administrator</span>
        </button>
      </div>

      {/* Active Admins Table */}
      <DataTable
        columns={adminColumns}
        data={admins}
        total={admins.length}
        page={1}
        limit={admins.length}
        totalPages={1}
        isLoading={loading}
        emptyMessage="No administrators configured."
      />

      {/* Pending Invitations Section */}
      <div className="pt-4 border-t border-surface-border space-y-3">
        <div>
          <h3 className="text-base font-bold text-text-primary">Pending Invitations</h3>
          <p className="text-xs text-text-secondary">
            Unaccepted single-use invitation tokens valid for 24 hours
          </p>
        </div>
        <DataTable
          columns={inviteColumns}
          data={invitations}
          total={invitations.length}
          page={1}
          limit={invitations.length}
          totalPages={1}
          isLoading={loading}
          emptyMessage="No pending invitations. All invited administrators have accepted their tokens."
        />
      </div>

      {/* Bootstrap CLI Instructions Card */}
      <div className="p-4 bg-surface-subtle rounded-lg border border-surface-border text-xs space-y-2">
        <div className="flex items-center space-x-2 font-bold text-text-primary">
          <Terminal className="w-4 h-4 text-forest" />
          <span>Initial System Provisioning Command</span>
        </div>
        <p className="text-text-secondary">
          For initial bootstrapping before any admin exists, run from the backend directory:
        </p>
        <pre className="bg-forest text-lime-accent p-2.5 rounded font-mono text-[11px] overflow-x-auto">
          python bootstrap_admin.py
        </pre>
        <p className="text-text-muted text-[11px]">
          Uses secure interactive hidden input via getpass. Refuses to execute if an administrator
          already exists.
        </p>
      </div>

      {/* Invite Modal */}
      {isInviteOpen && (
        <div className="fixed inset-0 z-50 overflow-y-auto bg-black/40 backdrop-blur-xs flex items-center justify-center p-4">
          <div className="bg-white rounded-lg max-w-lg w-full border border-surface-border shadow-xl overflow-hidden animate-in fade-in zoom-in-95 duration-150">
            <div className="px-6 py-4 border-b border-surface-border bg-surface-subtle flex justify-between items-center">
              <h3 className="text-base font-semibold text-text-primary">
                Invite New Administrator
              </h3>
              <button
                onClick={() => setIsInviteOpen(false)}
                className="text-text-secondary hover:text-text-primary"
              >
                ×
              </button>
            </div>

            {inviteResult ? (
              <div className="p-6 space-y-4">
                <div className="p-3 bg-emerald-50 border border-emerald-200 rounded text-xs text-emerald-900 flex items-start space-x-2">
                  <Check className="w-4 h-4 text-emerald-700 shrink-0 mt-0.5" />
                  <div>
                    <span className="font-bold">Admin Invitation Generated!</span>
                    <p className="mt-0.5">
                      {inviteResult.email_sent
                        ? 'An invitation email has been dispatched via configured SMTP.'
                        : 'SMTP credentials not configured or dispatch bypassed. Provide the direct onboarding link below to the administrator.'}
                    </p>
                  </div>
                </div>

                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1">
                    Single-Use Onboarding Link (Valid 24h)
                  </label>
                  <div className="flex items-center space-x-2">
                    <input
                      type="text"
                      readOnly
                      value={`${window.location.origin}/accept-invitation?token=${inviteResult.invite_token}`}
                      className="w-full text-xs font-mono rounded border border-surface-border px-3 py-2 bg-surface-bg text-text-primary select-all"
                    />
                    <button
                      type="button"
                      onClick={() =>
                        copyToClipboard(
                          `${window.location.origin}/accept-invitation?token=${inviteResult.invite_token}`
                        )
                      }
                      className="p-2 rounded border border-surface-border bg-white hover:bg-surface-subtle text-text-primary shrink-0"
                      title="Copy link"
                    >
                      {copied ? <Check className="w-4 h-4 text-emerald-600" /> : <Copy className="w-4 h-4" />}
                    </button>
                  </div>
                </div>

                <div className="flex justify-end pt-3 border-t border-surface-border">
                  <button
                    onClick={() => setIsInviteOpen(false)}
                    className="px-4 py-2 text-xs font-semibold rounded bg-forest text-white hover:bg-forest-light"
                  >
                    Done
                  </button>
                </div>
              </div>
            ) : (
              <form onSubmit={handleInviteSubmit} className="p-6 space-y-4">
                {inviteError && (
                  <div className="p-2.5 rounded bg-rose-50 border border-rose-200 text-xs text-rose-800">
                    {inviteError}
                  </div>
                )}

                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1">
                    Administrator Full Name <span className="text-rose-600">*</span>
                  </label>
                  <input
                    type="text"
                    required
                    value={fullName}
                    onChange={(e) => setFullName(e.target.value)}
                    placeholder="e.g. Anand Gowda"
                    className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                  />
                </div>

                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1">
                    Official Email Address <span className="text-rose-600">*</span>
                  </label>
                  <input
                    type="email"
                    required
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="anand@kisanrider.in"
                    className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                  />
                </div>

                <div className="p-3 bg-surface-subtle rounded border border-surface-border text-xs text-text-secondary space-y-1">
                  <span className="font-semibold text-text-primary block">Security Protocol:</span>
                  <p>
                    • No password is supplied by the inviting Admin. The new administrator chooses
                    their own password upon accepting the token.
                  </p>
                  <p>• Single-use token hash stored in database. Cannot be reused once activated.</p>
                </div>

                <div className="flex justify-end space-x-3 pt-3 border-t border-surface-border">
                  <button
                    type="button"
                    onClick={() => setIsInviteOpen(false)}
                    className="px-4 py-2 text-xs font-medium rounded border border-surface-border bg-white text-text-primary hover:bg-surface-subtle"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    disabled={inviteLoading}
                    className="px-4 py-2 text-xs font-semibold rounded bg-forest text-white hover:bg-forest-light transition-colors"
                  >
                    {inviteLoading ? 'Generating Token...' : 'Create & Send Invitation'}
                  </button>
                </div>
              </form>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
