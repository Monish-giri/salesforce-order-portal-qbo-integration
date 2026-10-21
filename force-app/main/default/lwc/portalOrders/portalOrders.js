import { LightningElement } from 'lwc';
import getOrders from '@salesforce/apex/PortalOrderService.getOrders';
import getOrderDetail from '@salesforce/apex/PortalOrderService.getOrderDetail';
import createReturnRequest from '@salesforce/apex/PortalReturnRequestService.createReturnRequest';

export default class PortalOrders extends LightningElement {
    orders = [];
    selectedOrder;
    isLoading = true;
    errorMessage;
    showReturnModal = false;
    returnReason = '';
    resolutionType = 'Applied to Invoice';
    returnQuantities = {};
    returnSubmitting = false;
    successMessage;

    connectedCallback() {
        this.loadOrders();
    }

    async loadOrders() {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            this.orders = await getOrders();
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
            this.orders = [];
        } finally {
            this.isLoading = false;
        }
    }

    async handleOrderClick(event) {
        const orderId = event.currentTarget.dataset.id;
        this.isLoading = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            this.selectedOrder = await getOrderDetail({ orderId });
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
            this.selectedOrder = undefined;
        } finally {
            this.isLoading = false;
        }
    }

    backToList() {
        this.selectedOrder = undefined;
        this.errorMessage = undefined;
        this.successMessage = undefined;
        this.closeReturnModal();
    }

    openReturnModal() {
        this.returnReason = '';
        this.resolutionType = 'Applied to Invoice';
        this.returnQuantities = {};
        this.errorMessage = undefined;
        this.successMessage = undefined;
        this.showReturnModal = true;
    }

    closeReturnModal() {
        if (this.returnSubmitting) return;
        this.showReturnModal = false;
        this.returnReason = '';
        this.returnQuantities = {};
    }

    handleReasonChange(event) {
        this.returnReason = event.target.value;
    }

    handleResolutionChange(event) {
        this.resolutionType = event.target.value;
    }

    handleQuantityChange(event) {
        const itemId = event.target.dataset.id;
        const value = event.target.value;
        const quantities = { ...this.returnQuantities };

        if (value === '' || value === null) {
            delete quantities[itemId];
        } else {
            quantities[itemId] = Number(value);
        }
        this.returnQuantities = quantities;
    }

    get returnLines() {
        return (this.selectedOrder?.lines || []).map(line => ({
            ...line,
            returnableQuantity: line.quantity,
            requestedQuantity: this.returnQuantities[line.id] || ''
        }));
    }

    get hasReturnLines() {
        return Object.keys(this.returnQuantities).length > 0;
    }

    get canSubmitReturn() {
        if (this.returnSubmitting || !this.selectedOrder || !this.hasReturnLines) return false;
        return Object.values(this.returnQuantities).every(quantity => Number(quantity) > 0);
    }

    get resolutionOptions() {
        return [
            { label: 'Applied to Invoice', value: 'Applied to Invoice' },
            { label: 'Refunded', value: 'Refunded' },
            { label: 'Customer Credit', value: 'Customer Credit' }
        ];
    }

    async submitReturnRequest() {
        if (!this.canSubmitReturn) {
            this.errorMessage = 'Enter a return quantity greater than zero for at least one item.';
            return;
        }

        this.returnSubmitting = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            await createReturnRequest({
                orderId: this.selectedOrder.id,
                requestedQuantities: this.returnQuantities,
                reason: this.returnReason,
                resolutionType: this.resolutionType
            });

            this.showReturnModal = false;
            this.returnQuantities = {};
            this.returnReason = '';
            this.successMessage = 'Return request submitted successfully.';
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
        } finally {
            this.returnSubmitting = false;
        }
    }

    get showList() {
        return !this.selectedOrder && !this.isLoading && this.orders.length > 0;
    }

    get showEmpty() {
        return !this.selectedOrder && !this.isLoading && this.orders.length === 0 && !this.errorMessage;
    }

    get showDetail() {
        return !!this.selectedOrder && !this.isLoading;
    }

    get isB2BInvoice() {
        return this.selectedOrder?.paymentMethod === 'Invoice';
    }

    get hasInvoiceBalance() {
        return this.selectedOrder?.invoiceBalance !== null && this.selectedOrder?.invoiceBalance !== undefined;
    }

    get hasCurrentDiscount() {
        return !!this.selectedOrder?.currentDiscount && this.selectedOrder.currentDiscount.eligible;
    }

    get currentDiscountPercent() {
        return this.selectedOrder?.currentDiscount?.discountPercent || 0;
    }

    get currentDiscountLabel() {
        return `${this.currentDiscountPercent}% available now`;
    }

    get currentDiscountMessage() {
        return this.selectedOrder?.currentDiscount?.message || 'Early-payment discount available.';
    }

    get paymentMethodLabel() {
        const method = this.selectedOrder?.paymentMethod;
        if (method === 'Cash on Delivery') return 'Cash on Delivery';
        if (method === 'Online') return 'Online Payment';
        return method || 'Payment';
    }

    getErrorMessage(error) {
        return error?.body?.message || error?.message || 'Unable to load orders.';
    }
}
