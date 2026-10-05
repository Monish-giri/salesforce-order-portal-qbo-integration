import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_NAME from '@salesforce/schema/User.Name';

const USER_FIELDS = [USER_NAME];

export default class OrderPortal extends LightningElement {
    activeSection = 'catalog';
    cartItems = [];
    showCart = false;

    @wire(getRecord, { recordId: USER_ID, fields: USER_FIELDS })
    userRecord;

    get userName() {
        return getFieldValue(this.userRecord?.data, USER_NAME) || 'Portal User';
    }

    get cartCount() {
        return this.cartItems.reduce((total, item) => total + item.quantity, 0);
    }

    get cartSubtotal() {
        return this.cartItems.reduce(
            (total, item) => total + (item.unitPrice * item.quantity),
            0
        );
    }

    get hasCartItems() {
        return this.cartItems.length > 0;
    }

    get isCatalog() {
        return this.activeSection === 'catalog' && !this.showCart;
    }

    get isCart() {
        return this.showCart;
    }

    get sectionTitle() {
        const titles = {
            orders: 'My Orders',
            returns: 'Returns'
        };
        return titles[this.activeSection] || 'Portal';
    }

    get catalogNavClass() {
        return this.navClass('catalog');
    }

    get ordersNavClass() {
        return this.navClass('orders');
    }

    get returnsNavClass() {
        return this.navClass('returns');
    }

    navClass(section) {
        return 'nav-item ' + (this.activeSection === section && !this.showCart ? 'active' : '');
    }

    handleNavigation(event) {
        const section = event.currentTarget.dataset.section;
        this.showCart = false;

        if (section === 'catalog') {
            this.activeSection = section;
        }
    }

    openCart() {
        this.showCart = true;
    }

    showCatalog() {
        this.showCart = false;
        this.activeSection = 'catalog';
    }

    handleAddToCart(event) {
        const product = event.detail;
        const existing = this.cartItems.find(
            item => item.pricebookEntryId === product.pricebookEntryId
        );

        if (existing) {
            this.cartItems = this.cartItems.map(item =>
                item.pricebookEntryId === product.pricebookEntryId
                    ? { ...item, quantity: item.quantity + product.quantity, lineTotal: item.unitPrice * (item.quantity + product.quantity) }
                    : item
            );
        } else {
            this.cartItems = [
                ...this.cartItems,
                { ...product, quantity: product.quantity, lineTotal: product.unitPrice * product.quantity }
            ];
        }
    }

    increaseQuantity(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems.map(item =>
            item.pricebookEntryId === id
                ? {
                    ...item,
                    quantity: item.quantity + 1,
                    lineTotal: item.unitPrice * (item.quantity + 1)
                }
                : item
        );
    }

    decreaseQuantity(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems
            .map(item =>
                item.pricebookEntryId === id
                    ? {
                        ...item,
                        quantity: item.quantity - 1,
                        lineTotal: item.unitPrice * (item.quantity - 1)
                    }
                    : item
            )
            .filter(item => item.quantity > 0);
    }

    removeItem(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems.filter(
            item => item.pricebookEntryId !== id
        );
    }
}
