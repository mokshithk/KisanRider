import React, { useState, useEffect } from 'react';
import {
  Search,
  Eye,
  RefreshCw,
  Package,
  MapPin,
  Calendar,
  AlertCircle,
  Truck,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import DetailModal from '../components/common/DetailModal';

export default function TransportRequests() {
  const [requests, setRequests] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchTerm, setSearchTerm] = useState('');
  const [cropType, setCropType] = useState('ALL');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedReq, setSelectedReq] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  const fetchRequests = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };
      if (searchTerm.trim()) params.search = searchTerm.trim();
      if (cropType !== 'ALL') params.crop_type = cropType;

      const res = await adminService.getRequests(params);
      setRequests(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch transport requests:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchRequests(1);
  }, [cropType, statusFilter]);

  const handleSearchSubmit = (e) => {
    e.preventDefault();
    fetchRequests(1);
  };

  const openDetail = async (req) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getRequestDetail(req.id);
      setSelectedReq(data);
    } catch (err) {
      console.error('Failed to load request detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const columns = [
    {
      header: 'Request ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-xs font-semibold text-text-primary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Farmer',
      accessor: 'farmer_name',
      render: (row) => (
        <div>
          <span className="font-medium text-text-primary block">{row.farmer_name}</span>
          <span className="text-[11px] text-text-secondary">{row.farmer_phone || '-'}</span>
        </div>
      ),
    },
    {
      header: 'Crop & Weight',
      accessor: 'crop_type',
      render: (row) => (
        <div>
          <span className="font-semibold text-forest block">{row.crop_type}</span>
          <span className="text-xs text-text-secondary">{row.weight_kg} kg</span>
        </div>
      ),
    },
    {
      header: 'Pickup Location',
      accessor: 'pickup_address',
      render: (row) => (
        <span className="truncate max-w-[160px] block" title={row.pickup_address}>
          {row.pickup_address || 'Farm Gate'}
        </span>
      ),
    },
    {
      header: 'Destination Market',
      accessor: 'dropoff_mandi_name',
      render: (row) => (
        <div>
          <span className="block font-medium text-text-primary truncate max-w-[160px]">
            {row.dropoff_mandi_name || 'APMC Mandi'}
          </span>
          <span className="text-[11px] text-text-secondary">{row.dropoff_district || 'Karnataka'}</span>
        </div>
      ),
    },
    {
      header: 'Status',
      accessor: 'status',
      render: (row) => <Badge status={row.status} />,
    },
    {
      header: 'Assigned Driver',
      accessor: 'assigned_rider',
      render: (row) => (
        <span className="text-xs text-text-secondary">
          {row.assigned_rider || <span className="text-text-muted italic">Unassigned</span>}
        </span>
      ),
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
        <button
          onClick={() => openDetail(row)}
          className="p-1.5 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
          title="Inspect Request"
        >
          <Eye className="w-4 h-4" />
        </button>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Search and Filters */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by crop, farmer, pickup address..."
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
          {/* Status Filter */}
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Statuses</option>
            <option value="PENDING">Pending</option>
            <option value="ACCEPTED">Accepted</option>
            <option value="IN_TRANSIT">In Transit</option>
            <option value="DELIVERED">Delivered</option>
            <option value="CANCELLED">Cancelled</option>
          </select>

          <button
            onClick={() => fetchRequests(page)}
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh list"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Requests Table */}
      <DataTable
        columns={columns}
        data={requests}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchRequests(p)}
        isLoading={loading}
        emptyMessage="No transport requests found matching your query."
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={
          selectedReq
            ? `Transport Request #${selectedReq.request.id.slice(0, 8)}`
            : 'Request Details'
        }
        subtitle={
          selectedReq?.request.created_at
            ? `Booked on ${new Date(selectedReq.request.created_at).toLocaleString()}`
            : ''
        }
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading request details...</div>
        ) : selectedReq ? (
          <div className="space-y-5">
            {/* Highlights */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Status</span>
                <Badge status={selectedReq.request.status} />
              </div>
              <div>
                <span className="text-text-secondary block">Crop Type</span>
                <span className="font-semibold text-text-primary block mt-0.5">{selectedReq.request.crop_type}</span>
              </div>
              <div>
                <span className="text-text-secondary block">Weight</span>
                <span className="font-semibold text-text-primary block mt-0.5">{selectedReq.request.weight_kg} kg</span>
              </div>
              <div>
                <span className="text-text-secondary block">Handoff OTP</span>
                <span className="font-mono font-bold text-forest block mt-0.5">{selectedReq.request.pickup_otp || 'N/A'}</span>
              </div>
            </div>

            {/* Farmer & Pickup */}
            <div className="p-3.5 bg-white rounded border border-surface-border space-y-2 text-xs">
              <h4 className="font-bold uppercase tracking-wider text-text-secondary">Producer & Pickup Point</h4>
              <p>
                <strong className="text-text-primary">Farmer:</strong> {selectedReq.farmer?.full_name} ({selectedReq.farmer?.phone || 'No phone'})
              </p>
              <p>
                <strong className="text-text-primary">Pickup Address:</strong> {selectedReq.request.pickup_address || 'Farm Gate'}
              </p>
              {selectedReq.request.pickup_landmark && (
                <p>
                  <strong className="text-text-primary">Landmark:</strong> {selectedReq.request.pickup_landmark}
                </p>
              )}
            </div>

            {/* Destination Mandi */}
            <div className="p-3.5 bg-white rounded border border-surface-border space-y-2 text-xs">
              <h4 className="font-bold uppercase tracking-wider text-text-secondary">Dropoff APMC Market</h4>
              <p>
                <strong className="text-text-primary">Mandi:</strong> {selectedReq.request.dropoff_mandi_name || 'APMC Yard'}
              </p>
              <p>
                <strong className="text-text-primary">District:</strong> {selectedReq.request.dropoff_district || 'Karnataka'}
              </p>
              {selectedReq.request.dropoff_stall_number && (
                <p>
                  <strong className="text-text-primary">Stall / Platform:</strong> {selectedReq.request.dropoff_stall_number}
                </p>
              )}
            </div>

            {/* Linked Trip */}
            {selectedReq.trip ? (
              <div className="p-3.5 bg-surface-subtle rounded border border-surface-border space-y-2 text-xs">
                <h4 className="font-bold uppercase tracking-wider text-text-secondary">Assigned Trip & Driver</h4>
                <div className="flex justify-between items-center">
                  <span>Trip #{selectedReq.trip.id?.slice(0, 8)}</span>
                  <Badge status={selectedReq.trip.status} />
                </div>
                <p>
                  <strong className="text-text-primary">Driver:</strong> {selectedReq.trip.rider_name || 'Unassigned'} ({selectedReq.trip.rider_phone || '-'})
                </p>
              </div>
            ) : (
              <div className="p-3 bg-surface-bg rounded border border-surface-border text-xs text-text-secondary italic">
                No driver trip currently dispatched for this produce request.
              </div>
            )}
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
