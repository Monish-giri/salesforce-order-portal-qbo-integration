import { LightningElement } from 'lwc';
import getOrders from '@salesforce/apex/PortalOrderService.getOrders';
import getOrderDetail from '@salesforce/apex/PortalOrderService.getOrderDetail';

export default class PortalOrders extends LightningElement {
    orders = [];
    selectedOrder;
    isLoading = true;
    errorMessage;

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
