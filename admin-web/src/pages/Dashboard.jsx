import React, { useState, useEffect } from 'react';
import {
  Users,
  Truck,
  PackageCheck,
  Navigation,
  CheckCircle,
  Layers,
  CircleDollarSign,
  IndianRupee,
  RefreshCw,
  AlertCircle,
  ArrowUpRight,
} from 'lucide-react';
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  PieChart,
  Pie,
  Cell,
  Legend,
} from 'recharts';
import { adminService } from '../services/adminService';
import StatCard from '../components/common/StatCard';
import Badge from '../components/common/Badge';

const PIE_COLORS = ['#173D2C', '#23533D', '#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#6B7280'];

export default function Dashboard() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const fetchStats = async () => {
    setLoading(true);
    setError('');
    try {
      const res = await adminService.getDashboardStats();
      setData(res);
    } catch (err) {
      console.error('Failed to load dashboard statistics:', err);
      setError('Failed to fetch dashboard metrics from backend. Please verify your connection.');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchStats();
  }, []);

  if (loading && !data) {
    return (
      <div className="flex items-center justify-center py-24">
        <div className="flex flex-col items-center space-y-3">
          <RefreshCw className="w-8 h-8 text-forest animate-spin" />
          <p className="text-xs font-medium text-text-secondary">Loading operational data...</p>
        </div>
      </div>
    );
  }

  if (error && !data) {
    return (
      <div className="bg-white rounded-lg border border-surface-border p-8 text-center max-w-lg mx-auto mt-12">
        <AlertCircle className="w-10 h-10 text-rose-600 mx-auto mb-3" />
        <h3 className="text-base font-bold text-text-primary">Unable to load dashboard</h3>
        <p className="text-xs text-text-secondary mt-1 mb-4">{error}</p>
        <button
          onClick={fetchStats}
          className="px-4 py-2 text-xs font-semibold rounded bg-forest text-white hover:bg-forest-light transition-colors"
        >
          Retry Connection
        </button>
      </div>
    );
  }

  const { cards, charts, recent } = data || {
    cards: {},
    charts: {},
    recent: {},
  };

  return (
    <div className="space-y-6">
      {/* Top Banner / Refresh */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 pb-2 border-b border-surface-border">
        <div>
          <h2 className="text-xl font-bold tracking-tight text-text-primary">
            KisanRider Operational Overview
          </h2>
          <p className="text-xs text-text-secondary mt-0.5">
            Real-time telemetry and supply chain statistics across Karnataka
          </p>
        </div>
        <button
          onClick={fetchStats}
          disabled={loading}
          className="inline-flex items-center space-x-2 px-3 py-1.5 rounded border border-surface-border bg-white text-xs font-medium text-text-primary hover:bg-surface-subtle transition-colors shadow-xs"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin text-forest' : ''}`} />
          <span>Refresh Data</span>
        </button>
      </div>

      {/* 8 Primary Cards Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Total Farmers"
          value={cards.total_farmers ?? 0}
          subtitle="Registered producer accounts"
          icon={Users}
        />
        <StatCard
          title="Total Riders"
          value={cards.total_riders ?? 0}
          subtitle="Registered transport vehicles"
          icon={Truck}
        />
        <StatCard
          title="Transport Requests"
          value={cards.total_requests ?? 0}
          subtitle="Farm-gate harvest dispatches"
          icon={PackageCheck}
        />
        <StatCard
          title="Total Trips"
          value={cards.total_trips ?? 0}
          subtitle="Freight journeys scheduled"
          icon={Navigation}
        />
        <StatCard
          title="Completed Trips"
          value={cards.completed_trips ?? 0}
          subtitle="Delivered to APMC Mandis"
          icon={CheckCircle}
          badge={`${
            cards.total_trips > 0
              ? Math.round((cards.completed_trips / cards.total_trips) * 100)
              : 0
          }% completion`}
        />
        <StatCard
          title="Active Pools"
          value={cards.active_pools ?? 0}
          subtitle="Open or in-progress freight pools"
          icon={Layers}
        />
        <StatCard
          title="Pending Settlements"
          value={cards.pending_settlements ?? 0}
          subtitle="Awaiting final reconciliation"
          icon={CircleDollarSign}
        />
        <StatCard
          title="Total Payout Volume"
          value={`₹${(cards.total_payout_volume || 0).toLocaleString('en-IN', {
            maximumFractionDigits: 2,
          })}`}
          subtitle="Gross driver & farmer transactions"
          icon={IndianRupee}
        />
      </div>

      {/* Visual Analytics / Charts */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Monthly Transportation Activity */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-sm font-bold text-text-primary">
                Monthly Transportation Activity
              </h3>
              <p className="text-xs text-text-secondary">Requests vs completed dispatches</p>
            </div>
          </div>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={charts.monthly_transportation || []} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#F0F3EF" />
                <XAxis dataKey="month" tick={{ fontSize: 11, fill: '#778179' }} />
                <YAxis tick={{ fontSize: 11, fill: '#778179' }} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ backgroundColor: '#FFFFFF', borderColor: '#E4EAE3', fontSize: 12, borderRadius: 6 }}
                />
                <Legend wrapperStyle={{ fontSize: 11, paddingTop: 8 }} />
                <Bar dataKey="requests" name="Transport Requests" fill="#173D2C" radius={[4, 4, 0, 0]} />
                <Bar dataKey="trips" name="Trips Scheduled" fill="#C8F53E" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* Trip Status Distribution */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-sm font-bold text-text-primary">
                Trip Status Distribution
              </h3>
              <p className="text-xs text-text-secondary">Current lifecycle distribution of trips</p>
            </div>
          </div>
          <div className="h-64 flex items-center justify-center">
            {charts.trip_status_distribution && charts.trip_status_distribution.length > 0 ? (
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie
                    data={charts.trip_status_distribution}
                    dataKey="count"
                    nameKey="status"
                    cx="50%"
                    cy="50%"
                    outerRadius={80}
                    innerRadius={45}
                    paddingAngle={3}
                  >
                    {charts.trip_status_distribution.map((entry, index) => (
                      <Cell key={`cell-${index}`} fill={PIE_COLORS[index % PIE_COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{ backgroundColor: '#FFFFFF', borderColor: '#E4EAE3', fontSize: 12, borderRadius: 6 }}
                  />
                  <Legend wrapperStyle={{ fontSize: 11 }} />
                </PieChart>
              </ResponsiveContainer>
            ) : (
              <p className="text-xs text-text-secondary">No trip records recorded yet.</p>
            )}
          </div>
        </div>

        {/* Farmer Registration Trends */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-sm font-bold text-text-primary">
                Farmer Onboarding Growth
              </h3>
              <p className="text-xs text-text-secondary">New verified producer registrations over time</p>
            </div>
          </div>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={charts.farmer_registration_trends || []} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#F0F3EF" />
                <XAxis dataKey="month" tick={{ fontSize: 11, fill: '#778179' }} />
                <YAxis tick={{ fontSize: 11, fill: '#778179' }} allowDecimals={false} />
                <Tooltip
                  contentStyle={{ backgroundColor: '#FFFFFF', borderColor: '#E4EAE3', fontSize: 12, borderRadius: 6 }}
                />
                <Line
                  type="monotone"
                  dataKey="farmers"
                  name="New Farmers"
                  stroke="#173D2C"
                  strokeWidth={2.5}
                  dot={{ r: 4, fill: '#C8F53E', stroke: '#173D2C' }}
                />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* District Transportation Breakdown */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-sm font-bold text-text-primary">
                Top Districts by Freight Volume
              </h3>
              <p className="text-xs text-text-secondary">Total harvest dispatches by destination district</p>
            </div>
          </div>
          <div className="h-64">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart
                layout="vertical"
                data={charts.district_activity || []}
                margin={{ top: 5, right: 20, left: 30, bottom: 5 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="#F0F3EF" />
                <XAxis type="number" tick={{ fontSize: 11, fill: '#778179' }} allowDecimals={false} />
                <YAxis type="category" dataKey="district" tick={{ fontSize: 11, fill: '#778179' }} />
                <Tooltip
                  contentStyle={{ backgroundColor: '#FFFFFF', borderColor: '#E4EAE3', fontSize: 12, borderRadius: 6 }}
                />
                <Bar dataKey="count" name="Transport Requests" fill="#23533D" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>

      {/* Operational Overview / Recent Tables Grid */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Recent Transport Requests */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4 pb-2 border-b border-surface-border">
            <h3 className="text-sm font-bold text-text-primary">Recent Requests</h3>
            <span className="text-[11px] text-text-secondary">Latest 5</span>
          </div>
          <div className="space-y-3">
            {recent.requests && recent.requests.length > 0 ? (
              recent.requests.map((req) => (
                <div key={req.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                  <div>
                    <span className="font-semibold text-text-primary block">{req.crop_type} ({req.weight_kg} kg)</span>
                    <span className="text-text-secondary block mt-0.5 truncate max-w-[180px]">{req.dropoff_mandi_name}</span>
                  </div>
                  <Badge status={req.status} />
                </div>
              ))
            ) : (
              <p className="text-xs text-text-secondary text-center py-4">No recent requests.</p>
            )}
          </div>
        </div>

        {/* Recent Trips */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4 pb-2 border-b border-surface-border">
            <h3 className="text-sm font-bold text-text-primary">Recent Trips</h3>
            <span className="text-[11px] text-text-secondary">Latest 5</span>
          </div>
          <div className="space-y-3">
            {recent.trips && recent.trips.length > 0 ? (
              recent.trips.map((trip) => (
                <div key={trip.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                  <div>
                    <span className="font-semibold text-text-primary block">Trip #{trip.id.slice(0, 8)}</span>
                    <span className="text-text-secondary block mt-0.5 truncate max-w-[180px]">{trip.pickup_address}</span>
                  </div>
                  <Badge status={trip.status} />
                </div>
              ))
            ) : (
              <p className="text-xs text-text-secondary text-center py-4">No recent trips.</p>
            )}
          </div>
        </div>

        {/* Latest Farmers */}
        <div className="bg-white rounded-lg border border-surface-border p-5 shadow-xs">
          <div className="flex items-center justify-between mb-4 pb-2 border-b border-surface-border">
            <h3 className="text-sm font-bold text-text-primary">New Farmers</h3>
            <span className="text-[11px] text-text-secondary">Latest 5</span>
          </div>
          <div className="space-y-3">
            {recent.farmers && recent.farmers.length > 0 ? (
              recent.farmers.map((farmer) => (
                <div key={farmer.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                  <div>
                    <span className="font-semibold text-text-primary block">{farmer.full_name}</span>
                    <span className="text-text-secondary block mt-0.5">{farmer.district} • {farmer.phone_number || 'No phone'}</span>
                  </div>
                  <Badge status={farmer.is_active ? 'ACTIVE' : 'SUSPENDED'} />
                </div>
              ))
            ) : (
              <p className="text-xs text-text-secondary text-center py-4">No farmers registered.</p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
