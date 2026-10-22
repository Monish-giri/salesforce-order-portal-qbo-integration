import { LightningElement, wire } from 'lwc';
import getReturns from '@salesforce/apex/PortalReturnService.getReturns';
import getReturnDetail from '@salesforce/apex/PortalReturnService.getReturnDetail';
import { refreshApex } from '@salesforce/apex';

export default class PortalReturns extends LightningElement {
    returns = [];
    errorMessage;
    wiredReturnsResult;
    isLoading = true;
    selectedReturn;
    isDetailLoading = false;
    detailError;

    @wire(getReturns)
    wiredReturns(result) {
        this.wiredReturnsResult = result;
        const { data, error } = result;
        if (data) {
            this.returns = data.map(item => ({
                ...item,
                statusClass: this.getStatusClass(item.status),
                resolutionLabel: item.resolutionType || 'Pending business decision',
                amountLabel: item.totalAmount || 0
            }));
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            this.returns = [];
            this.errorMessage = this.getErrorMessage(error);
            this.isLoading = false;
        }
    }

    async refreshReturns() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            await refreshApex(this.wiredReturnsResult);
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
        } finally {
            this.isLoading = false;
        }
    }

    async openReturn(event) {
        const returnId = event.currentTarget.dataset.id;
        if (!returnId) return;

        this.selectedReturn = undefined;
        this.detailError = undefined;
        this.isDetailLoading = true;

        try {
            const detail = await getReturnDetail({ returnId });
            this.selectedReturn = {
                ...detail,
                statusClass: this.getStatusClass(detail.status),
                resolutionLabel: detail.resolutionType || 'Pending business decision',
                amountLabel: detail.totalAmount || 0,
                lines: (detail.lines || []).map(line => ({
                    ...line,
                    quantityLabel: line.quantity || 0,
                    unitPriceLabel: line.unitPrice || 0,
                    lineAmountLabel: line.lineAmount || 0
                }))
            };
        } catch (error) {
            this.detailError = this.getErrorMessage(error);
        } finally {
            this.isDetailLoading = false;
        }
    }

    closeDetail() {
        this.selectedReturn = undefined;
        this.detailError = undefined;
    }

    get hasReturns() {
        return this.returns.length > 0;
    }

    get showEmpty() {
        return !this.isLoading && !this.errorMessage && !this.hasReturns;
    }

    get showDetail() {
        return this.isDetailLoading || !!this.selectedReturn || !!this.detailError;
    }

    getStatusClass(status) {
        const normalized = (status || '').toLowerCase();
        if (normalized === 'credited' || normalized === 'refunded') return 'status-badge success';
        if (normalized === 'failed' || normalized === 'rejected') return 'status-badge danger';
        if (normalized === 'approved' || normalized === 'processing') return 'status-badge progress';
        return 'status-badge pending';
    }

    getErrorMessage(error) {
        return error?.body?.message || error?.message || 'Unable to load returns.';
    }
}
