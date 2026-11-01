import React, { useState, useEffect } from 'react';
import {
  CircleDollarSign,
  Search,
  Eye,
  CheckCircle,
  RefreshCw,
  IndianRupee,
  AlertCircle,
  FileText,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import DetailModal from '../components/common/DetailModal';

export default function Settlements() {
  const [settlements, setSettlements] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedSettlement, setSelectedSettlement] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Reconciliation Modal
  const [reconcileModal, setReconcileModal] = useState({
    isOpen: false,
    settlement: null,
  });
  const [paymentRef, setPaymentRef] = useState('');
  const [reconcileNotes, setReconcileNotes] = useState('');
  const [reconcileError, setReconcileError] = useState('');
  const [reconcileLoading, setReconcileLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchSettlements = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };

      const res = await adminService.getSettlements(params);
      setSettlements(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch settlements:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchSettlements(1);
  }, [statusFilter]);

  const openDetail = async (s) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getSettlementDetail(s.id);
      setSelectedSettlement(data);
    } catch (err) {
      console.error('Failed to load settlement detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleReconcileSubmit = async (e) => {
    e.preventDefault();
    if (!paymentRef.trim()) {
      setReconcileError('External payment reference / UTR number is required.');
      return;
    }

    setReconcileLoading(true);
    setReconcileError('');
    try {
      await adminService.reconcileSettlement(
        reconcileModal.settlement.id,
        paymentRef.trim(),
        reconcileNotes.trim()
      );
      setToastMessage(
        `Settlement #${reconcileModal.settlement.id.slice(0, 8)} reconciled to PAID.`
      );
      setReconcileModal({ isOpen: false, settlement: null });
      setPaymentRef('');
      setReconcileNotes('');
      fetchSettlements(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to reconcile settlement:', err);
      const detail = err.response?.data?.detail || 'Reconciliation failed.';
      setReconcileError(detail);
    } finally {
      setReconcileLoading(false);
    }
  };

  const columns = [
    {
      header: 'Settlement ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-xs font-semibold text-text-primary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Farmer (Produce)',
      accessor: 'farmer_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.farmer_name}</span>
          <span className="text-[11px] text-text-secondary">
            {row.crop_name} ({row.quantity_kg || 0} kg)
          </span>
        </div>
      ),
    },
    {
      header: 'Rider Payee',
      accessor: 'rider_name',
      render: (row) => (
        <span className="font-medium text-text-primary text-xs">{row.rider_name}</span>
      ),
    },
    {
      header: 'Gross Amount',
      accessor: 'gross_amount',
      render: (row) => (
        <span className="text-xs font-semibold text-text-primary">
          ₹{(row.gross_amount || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Platform Fee (2%)',
      accessor: 'platform_fee',
      render: (row) => (
        <span className="text-xs text-text-secondary">
          ₹{(row.platform_fee || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Net Payout',
      accessor: 'net_payout',
      render: (row) => (
        <span className="text-xs font-bold text-forest">
          ₹{(row.net_payout || row.total_payout || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Payment Status',
      accessor: 'status',
      render: (row) => <Badge status={row.status} />,
    },
    {
      header: 'Date',
      accessor: 'created_at',
      render: (row) =>
        row.created_at ? new Date(row.created_at).toLocaleDateString() : '-',
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <div className="flex items-center justify-end space-x-1.5">
          <button
            onClick={() => openDetail(row)}
            className="p-1.5 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
            title="Inspect Settlement"
          >
            <Eye className="w-4 h-4" />
          </button>
          {row.status === 'PENDING' && (
            <button
              onClick={() => {
                setReconcileModal({ isOpen: true, settlement: row });
                setPaymentRef('');
                setReconcileNotes('');
                setReconcileError('');
              }}
              className="p-1.5 rounded text-emerald-700 hover:bg-emerald-50 transition-colors"
              title="Manual Reconciliation (Reconcile to PAID)"
            >
              <CheckCircle className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Information Header */}
      <div className="p-3.5 bg-white rounded-lg border border-surface-border text-xs text-text-secondary flex items-start space-x-2.5 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary">Financial Protocol:</strong> Real calculations
          based on base fare, distance rate (₹15/km), and crate load weight. Manual reconciliation
          requires an external bank transaction reference (UTR) and never claims automated funds
          transfer. All changes logged to audit trail.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Filter Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <div className="flex items-center space-x-3">
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Settlement Statuses</option>
            <option value="PENDING">Pending Reconciliation</option>
            <option value="PAID">Paid / Reconciled</option>
          </select>
        </div>

        <button
          onClick={() => fetchSettlements(page)}
          className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
          title="Refresh list"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </div>

      {/* Settlements Table */}
      <DataTable
        columns={columns}
        data={settlements}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchSettlements(p)}
        isLoading={loading}
        emptyMessage="No settlement records found."
      />

      {/* Reconciliation Modal */}
      {reconcileModal.isOpen && (
        <div className="fixed inset-0 z-50 overflow-y-auto bg-black/40 backdrop-blur-xs flex items-center justify-center p-4">
          <div className="bg-white rounded-lg max-w-md w-full border border-surface-border shadow-xl overflow-hidden animate-in fade-in zoom-in-95 duration-150">
            <div className="px-6 py-4 border-b border-surface-border bg-surface-subtle flex justify-between items-center">
              <h3 className="text-base font-semibold text-text-primary">
                Reconcile Settlement to PAID
              </h3>
              <button
                onClick={() => setReconcileModal({ isOpen: false, settlement: null })}
                className="text-text-secondary hover:text-text-primary"
              >
                ×
              </button>
            </div>
            <form onSubmit={handleReconcileSubmit} className="p-6 space-y-4">
              <div className="p-3 bg-surface-bg rounded border border-surface-border text-xs">
                <span className="text-text-secondary">Settlement ID:</span>{' '}
                <span className="font-mono font-semibold text-text-primary block">
                  #{reconcileModal.settlement?.id}
                </span>
                <span className="text-text-secondary mt-1 block">
                  Payee: {reconcileModal.settlement?.rider_name} • Net Payout: ₹{reconcileModal.settlement?.net_payout}
                </span>
              </div>

              {reconcileError && (
                <div className="p-2.5 rounded bg-rose-50 border border-rose-200 text-xs text-rose-800">
                  {reconcileError}
                </div>
              )}

              <div>
                <label className="block text-xs font-semibold text-text-primary mb-1">
                  External Payment Reference (UTR / Bank Ref) <span className="text-rose-600">*</span>
                </label>
                <input
                  type="text"
                  required
                  value={paymentRef}
                  onChange={(e) => setPaymentRef(e.target.value)}
                  placeholder="e.g. UTR-2026-HDFC-998822"
                  className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary font-mono"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-text-primary mb-1">
                  Reconciliation Notes
                </label>
                <textarea
                  value={reconcileNotes}
                  onChange={(e) => setReconcileNotes(e.target.value)}
                  placeholder="e.g. Verified with bank statement for batch dispatch #44"
                  rows={2}
                  className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                />
              </div>

              <div className="flex justify-end space-x-3 pt-3 border-t border-surface-border">
                <button
                  type="button"
                  onClick={() => setReconcileModal({ isOpen: false, settlement: null })}
                  className="px-4 py-2 text-xs font-medium rounded border border-surface-border bg-white text-text-primary hover:bg-surface-subtle"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={reconcileLoading}
                  className="px-4 py-2 text-xs font-medium rounded bg-forest text-white hover:bg-forest-light transition-colors"
                >
                  {reconcileLoading ? 'Saving...' : 'Confirm Paid Status'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedSettlement ? `Settlement #${selectedSettlement.settlement.id.slice(0, 8)}` : 'Settlement'}
        subtitle={`Created on ${selectedSettlement?.settlement.created_at ? new Date(selectedSettlement.settlement.created_at).toLocaleDateString() : ''}`}
        maxWidth="max-w-2xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading settlement...</div>
        ) : selectedSettlement ? (
          <div className="space-y-5">
            {/* Highlights */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Status</span>
                <Badge status={selectedSettlement.settlement.status} />
              </div>
              <div>
                <span className="text-text-secondary block">Gross Fare</span>
                <span className="font-semibold text-text-primary block mt-0.5">₹{selectedSettlement.settlement.gross_amount}</span>
              </div>
              <div>
                <span className="text-text-secondary block">Platform Fee</span>
                <span className="font-semibold text-text-primary block mt-0.5">₹{selectedSettlement.settlement.platform_fee}</span>
              </div>
              <div>
                <span className="text-text-secondary block">Net Driver Payout</span>
                <span className="font-bold text-forest block mt-0.5">₹{selectedSettlement.settlement.net_payout}</span>
              </div>
            </div>

            {/* Fare Breakdown */}
            <div className="p-3.5 bg-white rounded border border-surface-border text-xs space-y-2">
              <span className="font-bold uppercase tracking-wider text-text-secondary block">
                Calculated Distance & Weight Formula
              </span>
              <div className="flex justify-between py-1 border-b border-surface-border">
                <span className="text-text-secondary">Base Fare:</span>
                <span className="font-medium text-text-primary">₹{selectedSettlement.settlement.base_fare}</span>
              </div>
              <div className="flex justify-between py-1 border-b border-surface-border">
                <span className="text-text-secondary">Distance Fare:</span>
                <span className="font-medium text-text-primary">₹{selectedSettlement.settlement.distance_fare}</span>
              </div>
              <div className="flex justify-between py-1 border-b border-surface-border">
                <span className="text-text-secondary">Weight Surcharge:</span>
                <span className="font-medium text-text-primary">₹{selectedSettlement.settlement.weight_surcharge}</span>
              </div>
              <div className="flex justify-between py-1 pt-2 font-bold text-text-primary">
                <span>Total Payout:</span>
                <span className="text-forest">₹{selectedSettlement.settlement.total_payout}</span>
              </div>
            </div>

            {/* Linked Parties */}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs bg-surface-bg p-3.5 rounded border border-surface-border">
              <div>
                <span className="font-bold text-text-primary block">Producer (Farmer)</span>
                <p className="text-text-secondary mt-0.5">{selectedSettlement.farmer?.full_name}</p>
                <p className="text-text-muted text-[11px]">Bank: {selectedSettlement.farmer?.bank_name || 'N/A'}</p>
                <p className="text-text-muted text-[11px]">UPI: {selectedSettlement.farmer?.upi_id || 'N/A'}</p>
              </div>
              <div>
                <span className="font-bold text-text-primary block">Transporter (Rider)</span>
                <p className="text-text-secondary mt-0.5">{selectedSettlement.rider?.full_name}</p>
                <p className="text-text-muted text-[11px]">Bank: {selectedSettlement.rider?.bank_name || 'N/A'}</p>
                <p className="text-text-muted text-[11px]">UPI: {selectedSettlement.rider?.upi_id || 'N/A'}</p>
              </div>
            </div>
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
