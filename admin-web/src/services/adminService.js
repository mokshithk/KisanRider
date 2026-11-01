import api from './api';

export const adminService = {
  // Auth
  async login(email, password) {
    const res = await api.post('/admin/auth/login', { email, password });
    return res.data;
  },

  async getProfile() {
    const res = await api.get('/admin/auth/me');
    return res.data;
  },

  async changePassword(currentPassword, newPassword) {
    const res = await api.post('/admin/auth/change-password', {
      current_password: currentPassword,
      new_password: newPassword,
    });
    return res.data;
  },

  // Dashboard
  async getDashboardStats() {
    const res = await api.get('/admin/dashboard/stats');
    return res.data;
  },

  // Farmers
  async getFarmers(params = {}) {
    const res = await api.get('/admin/farmers', { params });
    return res.data;
  },

  async getFarmerDetail(id) {
    const res = await api.get(`/admin/farmers/${id}`);
    return res.data;
  },

  async updateFarmerStatus(id, isActive, reason) {
    const res = await api.patch(`/admin/farmers/${id}/status`, {
      is_active: isActive,
      reason,
    });
    return res.data;
  },

  // Riders
  async getRiders(params = {}) {
    const res = await api.get('/admin/riders', { params });
    return res.data;
  },

  async getRiderDetail(id) {
    const res = await api.get(`/admin/riders/${id}`);
    return res.data;
  },

  async updateRiderStatus(id, isActive, reason) {
    const res = await api.patch(`/admin/riders/${id}/status`, {
      is_active: isActive,
      reason,
    });
    return res.data;
  },

  // Transport Requests
  async getRequests(params = {}) {
    const res = await api.get('/admin/requests', { params });
    return res.data;
  },

  async getRequestDetail(id) {
    const res = await api.get(`/admin/requests/${id}`);
    return res.data;
  },

  // Trips
  async getTrips(params = {}) {
    const res = await api.get('/admin/trips', { params });
    return res.data;
  },

  async getTripDetail(id) {
    const res = await api.get(`/admin/trips/${id}`);
    return res.data;
  },

  async cancelTrip(id, reason) {
    const res = await api.post(`/admin/trips/${id}/cancel`, { reason });
    return res.data;
  },

  // Farmer Pools
  async getPools(params = {}) {
    const res = await api.get('/admin/pools', { params });
    return res.data;
  },

  async getPoolDetail(id) {
    const res = await api.get(`/admin/pools/${id}`);
    return res.data;
  },

  async cancelPool(id, reason) {
    const res = await api.post(`/admin/pools/${id}/cancel`, { reason });
    return res.data;
  },

  // Settlements
  async getSettlements(params = {}) {
    const res = await api.get('/admin/settlements', { params });
    return res.data;
  },

  async getSettlementDetail(id) {
    const res = await api.get(`/admin/settlements/${id}`);
    return res.data;
  },

  async reconcileSettlement(id, paymentReference, notes) {
    const res = await api.patch(`/admin/settlements/${id}/reconcile`, {
      payment_reference: paymentReference,
      notes,
    });
    return res.data;
  },

  // Mandi Prices
  async getMandiPrices(params = {}) {
    const res = await api.get('/admin/mandi/prices', { params });
    return res.data;
  },

  // Reports
  async getReportsSummary(category, startDate, endDate) {
    const params = { category };
    if (startDate) params.start_date = startDate;
    if (endDate) params.end_date = endDate;
    const res = await api.get('/admin/reports/summary', { params });
    return res.data;
  },

  async downloadReportCsv(category, startDate, endDate) {
    const params = { category };
    if (startDate) params.start_date = startDate;
    if (endDate) params.end_date = endDate;
    const res = await api.get('/admin/reports/export', {
      params,
      responseType: 'blob',
    });
    
    // Create download link in browser
    const blob = new Blob([res.data], { type: 'text/csv' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `kisanrider_${category}_export_${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
  },

  // Admin Management
  async getAdmins() {
    const res = await api.get('/admin/admins');
    return res.data;
  },

  async inviteAdmin(email, fullName) {
    const res = await api.post('/admin/admins/invite', {
      email,
      full_name: fullName,
    });
    return res.data;
  },

  async resendInvite(invitationId) {
    const res = await api.post('/admin/admins/resend-invite', {
      invitation_id: invitationId,
    });
    return res.data;
  },

  async acceptInvite(token, password) {
    const res = await api.post('/admin/admins/accept-invite', {
      token,
      password,
    });
    return res.data;
  },

  // Activity Logs
  async getActivityLogs(params = {}) {
    const res = await api.get('/admin/activity-logs', { params });
    return res.data;
  },

  async getActivityLogDetail(id) {
    const res = await api.get(`/admin/activity-logs/${id}`);
    return res.data;
  },
};
