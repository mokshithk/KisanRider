import React, { useState, useEffect } from 'react';
import {
  Search,
  Filter,
  Eye,
  UserX,
  UserCheck,
  RefreshCw,
  MapPin,
  Calendar,
  AlertCircle,
  FileText,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import ConfirmationModal from '../components/common/ConfirmationModal';
import DetailModal from '../components/common/DetailModal';

export default function Farmers() {
  const [farmers, setFarmers] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchTerm, setSearchTerm] = useState('');
  const [district, setDistrict] = useState('ALL');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal State
  const [selectedFarmer, setSelectedFarmer] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Action Confirmation Modal State
  const [confirmModal, setConfirmModal] = useState({
    isOpen: false,
    farmer: null,
    targetActive: false,
  });
  const [actionLoading, setActionLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchFarmers = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };
      if (searchTerm.trim()) params.search = searchTerm.trim();
      if (district !== 'ALL') params.district = district;

      const res = await adminService.getFarmers(params);
      setFarmers(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch farmers:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchFarmers(1);
  }, [district, statusFilter]);

  const handleSearchSubmit = (e) => {
    e.preventDefault();
    fetchFarmers(1);
  };

  const openDetail = async (farmer) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getFarmerDetail(farmer.id);
      setSelectedFarmer(data);
    } catch (err) {
      console.error('Failed to load farmer detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleStatusChangeConfirm = async (reason) => {
    const { farmer, targetActive } = confirmModal;
    if (!farmer) return;

    setActionLoading(true);
    try {
      await adminService.updateFarmerStatus(farmer.id, targetActive, reason);
      setToastMessage(
        `Farmer ${farmer.full_name} has been ${targetActive ? 'reactivated' : 'suspended'}.`
      );
      setConfirmModal({ isOpen: false, farmer: null, targetActive: false });
      fetchFarmers(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to update status:', err);
      alert('Failed to update account status. Please check backend logs.');
    } finally {
      setActionLoading(false);
    }
  };

  const columns = [
    {
      header: 'Farmer Name',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.full_name}</span>
          <span className="text-xs text-text-secondary">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'Phone Number',
      accessor: 'phone_number',
      render: (row) => row.phone_number || row.phone || '-',
    },
    {
      header: 'District',
      accessor: 'district',
      render: (row) => (
        <div>
          <span className="block text-text-primary">{row.district || 'Karnataka'}</span>
          {row.taluk_village && (
            <span className="text-[11px] text-text-secondary">{row.taluk_village}</span>
          )}
        </div>
      ),
    },
    {
      header: 'Farm Size',
      accessor: 'farm_size_acres',
      render: (row) => (row.farm_size_acres ? `${row.farm_size_acres} Acres` : '-'),
    },
    {
      header: 'Primary Crops',
      accessor: 'primary_crops',
      render: (row) => (
        <span className="truncate max-w-[140px] block" title={row.primary_crops}>
          {row.primary_crops || '-'}
        </span>
      ),
    },
    {
      header: 'Registered',
      accessor: 'created_at',
      render: (row) =>
        row.created_at ? new Date(row.created_at).toLocaleDateString() : '-',
    },
    {
      header: 'Status',
      accessor: 'is_active',
      render: (row) => (
        <Badge status={row.is_active ? 'ACTIVE' : 'SUSPENDED'} />
      ),
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <div className="flex items-center justify-end space-x-1.5">
          <button
            onClick={() => openDetail(row)}
            className="p-1 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
            title="View Details"
          >
            <Eye className="w-4 h-4" />
          </button>
          {row.is_active ? (
            <button
              onClick={() =>
                setConfirmModal({
                  isOpen: true,
                  farmer: row,
                  targetActive: false,
                })
              }
              className="p-1 rounded text-rose-600 hover:bg-rose-50 transition-colors"
              title="Suspend Farmer Account"
            >
              <UserX className="w-4 h-4" />
            </button>
          ) : (
            <button
              onClick={() =>
                setConfirmModal({
                  isOpen: true,
                  farmer: row,
                  targetActive: true,
                })
              }
              className="p-1 rounded text-emerald-700 hover:bg-emerald-50 transition-colors"
              title="Reactivate Farmer Account"
            >
              <UserCheck className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Informational callout regarding automatic registration */}
      <div className="p-3.5 bg-white rounded-lg border border-surface-border text-xs text-text-secondary flex items-start space-x-2.5 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary">Policy Note:</strong> Farmer registration is
          automatic based on mobile credentials and OTP verification. Admins may inspect verified
          producer accounts, review farm profiles, and perform account suspension or reactivation
          with full audit trail recording.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by farmer name, email, phone, village..."
              className="w-full text-xs rounded border border-surface-border pl-9 pr-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>
          <button
            type="submit"
            className="px-3.5 py-2 text-xs font-medium rounded bg-forest text-white hover:bg-forest-light transition-colors"
          >
            Search
          </button>
        </form>

        <div className="flex items-center space-x-3">
          {/* Status filter */}
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Statuses</option>
            <option value="ACTIVE">Active Accounts</option>
            <option value="SUSPENDED">Suspended Accounts</option>
          </select>

          <button
            onClick={() => fetchFarmers(page)}
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh list"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Farmers Data Table */}
      <DataTable
        columns={columns}
        data={farmers}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchFarmers(p)}
        isLoading={loading}
        emptyMessage="No registered farmer records found."
      />

      {/* Consequential Action Confirmation Modal */}
      <ConfirmationModal
        isOpen={confirmModal.isOpen}
        onClose={() => setConfirmModal({ isOpen: false, farmer: null, targetActive: false })}
        onConfirm={handleStatusChangeConfirm}
        title={confirmModal.targetActive ? 'Reactivate Farmer Account' : 'Suspend Farmer Account'}
        actionType={confirmModal.targetActive ? 'primary' : 'danger'}
        affectedRecord={
          confirmModal.farmer
            ? `${confirmModal.farmer.full_name} (${confirmModal.farmer.email})`
            : ''
        }
        consequences={
          confirmModal.targetActive
            ? 'The farmer will immediately regain access to book dispatches, participate in farmer pools, and receive mandi payouts.'
            : 'The farmer will be immediately blocked from booking produce transportation, joining pools, or logging into the mobile application.'
        }
        requireReason={true}
        reasonPlaceholder="Specify administrative reason for this status modification..."
        confirmText={confirmModal.targetActive ? 'Confirm Reactivation' : 'Confirm Suspension'}
        isLoading={actionLoading}
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedFarmer?.farmer.full_name || 'Farmer Details'}
        subtitle={`Registered on ${
          selectedFarmer?.farmer.created_at
            ? new Date(selectedFarmer.farmer.created_at).toLocaleDateString()
            : '-'
        }`}
        maxWidth="max-w-3xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading profile...</div>
        ) : selectedFarmer ? (
          <div className="space-y-6">
            {/* Top Overview Cards */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Account Status</span>
                <Badge status={selectedFarmer.farmer.is_active ? 'ACTIVE' : 'SUSPENDED'} />
              </div>
              <div>
                <span className="text-text-secondary block">District</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedFarmer.farmer.district || 'Karnataka'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Farm Size</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedFarmer.farmer.farm_size_acres ? `${selectedFarmer.farmer.farm_size_acres} Acres` : '-'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Phone</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedFarmer.farmer.phone_number || '-'}
                </span>
              </div>
            </div>

            {/* Farm & Contact Information */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Farm & Banking Details
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs bg-white p-3.5 rounded border border-surface-border">
                <div>
                  <span className="text-text-secondary">Primary Crops:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedFarmer.farmer.primary_crops || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Taluk / Village:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedFarmer.farmer.taluk_village || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Farm Address:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedFarmer.farmer.farm_address || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Bank / IFSC:</span>{' '}
                  <span className="font-medium text-text-primary">
                    {selectedFarmer.farmer.bank_name ? `${selectedFarmer.farmer.bank_name} (${selectedFarmer.farmer.ifsc_code || ''})` : '-'}
                  </span>
                </div>
                <div>
                  <span className="text-text-secondary">Account Number:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedFarmer.farmer.account_number || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">UPI ID:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedFarmer.farmer.upi_id || '-'}</span>
                </div>
              </div>
            </div>

            {/* Saved Addresses */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Saved Pickup Addresses ({selectedFarmer.saved_addresses?.length || 0})
              </h4>
              <div className="space-y-2">
                {selectedFarmer.saved_addresses?.length > 0 ? (
                  selectedFarmer.saved_addresses.map((addr) => (
                    <div key={addr.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs">
                      <span className="font-semibold text-text-primary block">{addr.title}</span>
                      <p className="text-text-secondary mt-0.5">{addr.address_text}</p>
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No saved bookmarked addresses.</p>
                )}
              </div>
            </div>

            {/* Recent Transport Requests */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Recent Transportation History ({selectedFarmer.requests?.length || 0})
              </h4>
              <div className="space-y-2">
                {selectedFarmer.requests?.length > 0 ? (
                  selectedFarmer.requests.slice(0, 5).map((r) => (
                    <div key={r.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                      <div>
                        <span className="font-semibold text-text-primary block">
                          {r.crop_type} • {r.weight_kg} kg
                        </span>
                        <span className="text-text-secondary text-[11px] block mt-0.5">
                          To: {r.dropoff_mandi_name}
                        </span>
                      </div>
                      <Badge status={r.status} />
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No produce transport requests booked yet.</p>
                )}
              </div>
            </div>
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
