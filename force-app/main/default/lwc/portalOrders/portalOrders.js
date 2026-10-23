import { LightningElement } from 'lwc';
import getOrders from '@salesforce/apex/PortalOrderService.getOrders';
import getOrderDetail from '@salesforce/apex/PortalOrderService.getOrderDetail';
import createReturnRequest from '@salesforce/apex/PortalReturnRequestService.createReturnRequest';
import createPaymentOrder from '@salesforce/apex/RazorpayPaymentService.createPaymentOrder';
import verifyPayment from '@salesforce/apex/RazorpayPaymentService.verifyPayment';

export default class PortalOrders extends LightningElement {
    orders = [];
    selectedOrder;
    isLoading = true;
    isPaymentProcessing = false;
    paymentWindow;
    errorMessage;
    showReturnModal = false;
    returnReason = '';
    returnQuantities = {};
    returnSubmitting = false;
    successMessage;

    connectedCallback() {
        this.loadOrders();
        window.addEventListener('message', this.handlePaymentMessage);
    }

    disconnectedCallback() {
        window.removeEventListener('message', this.handlePaymentMessage);
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
        this.returnQuantities = {};
        this.errorMessage = undefined;
        this.successMessage = undefined;
        this.showReturnModal = true;
    }

    closeReturnModal() {
        if (this.returnSubmitting || this.isPaymentProcessing) return;
        this.showReturnModal = false;
        this.returnReason = '';
        this.returnQuantities = {};
    }

    handleReasonChange(event) {
        this.returnReason = event.target.value;
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

    get isReturnSubmitDisabled() {
        return !this.canSubmitReturn;
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
                reason: this.returnReason
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

    get canPayOnline() {
        const order = this.selectedOrder;
        if (!order || this.isPaymentProcessing) return false;
        if (order.paymentStatus === 'Paid') return false;

        // Explicitly disallow COD. Invoice and Online are payable through Razorpay.
        // A null payment method is treated as legacy online payment so older orders
        // created before Payment_Method__c was populated remain payable.
        if (order.paymentMethod === 'Cash on Delivery') return false;
        if (order.paymentMethod && !['Online', 'Invoice'].includes(order.paymentMethod)) return false;

        if (order.invoiceStatus !== 'Invoiced') return false;
        return Number(order.invoiceBalance) > 0;
    }

    get payButtonLabel() {
        return this.isPaymentProcessing ? 'Opening Payment...' : 'Pay Now';
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
        if (method === 'Invoice') return 'B2B Invoice / Credit Terms';

        // Legacy orders created before Payment_Method__c was populated can still
        // be paid online when an invoice and outstanding balance exist.
        if (this.canPayOnline) return 'Online Payment';
        return method || 'Payment';
    }

    async handlePayNow() {
        if (!this.canPayOnline) return;

        this.errorMessage = undefined;
        this.successMessage = undefined;
        this.isPaymentProcessing = true;

        this.paymentWindow = window.open(
            'about:blank',
            'razorpayCheckout',
            'width=500,height=760,resizable=yes,scrollbars=yes'
        );

        if (!this.paymentWindow) {
            this.isPaymentProcessing = false;
            this.errorMessage = 'Your browser blocked the payment window. Please allow pop-ups for the Order Portal and try again.';
            return;
        }

        try {
            const paymentOrder = await createPaymentOrder({
                orderId: this.selectedOrder.id
            });

            const checkoutUrl = this.buildRazorpayCheckoutUrl(paymentOrder);
            this.paymentWindow.location.href = checkoutUrl;
            this.paymentWindow.focus();
        } catch (error) {
            if (this.paymentWindow && !this.paymentWindow.closed) {
                this.paymentWindow.close();
            }
            this.paymentWindow = undefined;
            this.isPaymentProcessing = false;
            this.errorMessage = this.getErrorMessage(error);
        }
    }

    buildRazorpayCheckoutUrl(paymentOrder) {
        const pathSegments = window.location.pathname.split('/').filter(Boolean);
        const sitePrefix = pathSegments[0];

        // The Order Portal is exposed at /orderportal, while the Visualforce
        // bridge has its own custom URL at /orderportalvforcesite.
        // Do not add the site prefix a second time.
        const visualforcePath = sitePrefix
            ? `/${sitePrefix}vforcesite/RazorpayCheckoutBridge`
            : '/vforcesite/RazorpayCheckoutBridge';

        const params = new URLSearchParams({
            keyId: paymentOrder.keyId,
            amount: String(paymentOrder.amountPaise),
            currency: paymentOrder.currencyCode,
            orderId: paymentOrder.razorpayOrderId,
            receipt: paymentOrder.receipt,
            parentOrigin: window.location.origin
        });

        return `${window.location.origin}${visualforcePath}?${params.toString()}`;
    }

    handlePaymentMessage = (event) => {
        if (!this.paymentWindow || event.source !== this.paymentWindow) {
            return;
        }

        const message = event.data || {};
        if (!['razorpay-success', 'razorpay-error', 'razorpay-dismissed'].includes(message.type)) {
            return;
        }

        if (message.type === 'razorpay-success') {
            this.handleRazorpaySuccess({
                razorpay_payment_id: message.payload?.razorpayPaymentId,
                razorpay_order_id: message.payload?.razorpayOrderId,
                razorpay_signature: message.payload?.razorpaySignature
            });
            return;
        }

        this.isPaymentProcessing = false;

        if (message.type === 'razorpay-dismissed') {
            this.errorMessage = 'Payment was not completed. Your order is saved and you can try again.';
        } else {
            this.errorMessage = message.payload?.message || 'Razorpay payment failed. Please try again.';
        }

        this.paymentWindow = undefined;
    };

    async handleRazorpaySuccess(response) {
        try {
            this.isPaymentProcessing = true;
            this.errorMessage = undefined;

            const verification = await verifyPayment({
                orderId: this.selectedOrder.id,
                razorpayPaymentId: response?.razorpay_payment_id,
                razorpayOrderId: response?.razorpay_order_id,
                razorpaySignature: response?.razorpay_signature
            });

            if (!verification?.success) {
                throw new Error('Razorpay payment could not be verified.');
            }

            this.successMessage = 'Payment completed successfully.';
            this.selectedOrder = await getOrderDetail({ orderId: this.selectedOrder.id });
        } catch (error) {
            this.errorMessage = this.getErrorMessage(error);
        } finally {
            this.isPaymentProcessing = false;
            this.paymentWindow = undefined;
        }
    }

    getErrorMessage(error) {
        return error?.body?.message || error?.message || 'Unable to load orders.';
    }
}
