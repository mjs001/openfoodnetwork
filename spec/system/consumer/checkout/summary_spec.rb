# frozen_string_literal: true

require "system_helper"

RSpec.describe "As a consumer, I want to checkout my order" do
  include ShopWorkflow
  include CheckoutHelper
  include FileHelper
  include StripeHelper
  include StripeStubs
  include PaypalHelper
  include AuthenticationHelper
  include UIComponentHelper

  let!(:zone) { create(:zone_with_member) }
  let(:supplier) { create(:supplier_enterprise) }
  let(:distributor) { create(:distributor_enterprise, charges_sales_tax: true) }
  let(:product) {
    create(:taxed_product, supplier_id: supplier.id, price: 10, zone:, tax_rate_amount: 0.1)
  }
  let(:variant) { product.variants.first }
  let!(:order_cycle) {
    create(:simple_order_cycle, suppliers: [supplier], distributors: [distributor],
                                coordinator: create(:distributor_enterprise), variants: [variant])
  }
  let(:order) {
    create(:order, order_cycle:, distributor:, bill_address_id: nil,
                   ship_address_id: nil, state: "cart",
                   line_items: [create(:line_item, variant:)])
  }
  let(:fee_tax_rate) { create(:tax_rate, amount: 0.10, zone:, included_in_price: true) }
  let(:fee_tax_category) { create(:tax_category, tax_rates: [fee_tax_rate]) }
  let(:enterprise_fee) { create(:enterprise_fee, amount: 1.23, tax_category: fee_tax_category) }

  let(:free_shipping_with_required_address) {
    create(:shipping_method, require_ship_address: true,
                             name: "A Free Shipping with required address")
  }

  before do
    add_enterprise_fee enterprise_fee
    pick_order order

    distributor.shipping_methods.push(free_shipping_with_required_address)
  end

  context "as a logged in user" do
    let(:user) { create(:user) }

    before do
      login_as(user)
    end

    context "summary step" do
      let(:order) {
        create(:order_ready_for_confirmation, distributor:)
      }

      describe "display the delivery address and not the ship address" do
        let(:ship_address) { create(:address, :randomized) }
        let(:bill_address) { create(:address, :randomized) }

        before do
          order.update_attribute(:ship_address, ship_address)
          order.update_attribute(:bill_address, bill_address)
          visit checkout_step_path(:summary)
        end

        it "displays title and ship address" do
          expect(page).to have_title "Checkout Summary - Open Food Network"

          expect(page).to have_content "Delivery address"
          expect(page).to have_content order.ship_address.address1
          expect(page).to have_content order.ship_address.city
          expect(page).to have_content order.ship_address.zipcode
          expect(page).to have_content order.ship_address.phone

          # but not the billing address
          expect(page).not_to have_content order.bill_address.address1
          expect(page).not_to have_content order.bill_address.city
          expect(page).not_to have_content order.bill_address.zipcode
          expect(page).not_to have_content order.bill_address.phone
        end
      end

      describe "with an order with special instructions" do
        before do
          order.update_attribute(:special_instructions, "Please deliver on Tuesday")
          visit checkout_step_path(:summary)
        end

        it "displays the special instructions" do
          expect(page).to have_content "Please deliver on Tuesday"
        end
      end

      describe "completing the checkout" do
        it "keeps the distributor selected for the current user after completion" do
          visit checkout_step_path(:summary)

          expect(page).to have_content "Shopping @ #{distributor.name}"

          place_order

          expect(page).to have_content "Back To Store"
          expect(order.reload.state).to eq "complete"

          expect(page).to have_content "Shopping @ #{distributor.name}"
        end
      end

      describe "navigating away from checkout summary page" do
        it "navigates to new page when popup is confirmed" do
          visit checkout_step_path(:summary)
          expect(page).to have_content "Order summary"
          within '.nav-main-menu' do
            accept_alert do
              click_link(href: '/groups')
            end
          end
          expect(page).not_to have_content "Order summary"
          expect(page).to have_content "Groups / regions"
        end

        it "doesn't navigate to new page when popup is canceled" do
          visit checkout_step_path(:summary)
          expect(page).to have_content "Order summary"
          within '.nav-main-menu' do
            dismiss_confirm do
              click_link(href: '/groups')
            end
          end
          expect(page).to have_content "Order summary"
          expect(page).not_to have_content "Groups / regions"
        end

        it "opens correct order step when edit link is clicked" do
          visit checkout_step_path(:summary)
          expect(page).to have_content "Order summary"
          click_link(href: '/checkout/details')

          expect(page).to have_content "Contact information"
          expect(page).not_to have_content "Groups / regions"
        end
      end

      describe "navigation available" do
        it "redirect to Payment method step by clicking on 'Payment method' link" do
          visit checkout_step_path(:summary)

          click_link "Payment method"

          expect(page).to have_content("You can review and confirm your order in the next step " \
                                       "which includes the final costs.")
        end
      end

      describe "terms and conditions" do
        let(:customer) { create(:customer, enterprise: order.distributor, user:) }
        let(:tos_url) { "https://example.org/tos" }
        let(:system_terms) { terms_pdf_file }
        let(:shop_terms) { terms_pdf_file }

        context "when none are required" do
          it "doesn't show checkbox or links" do
            visit checkout_step_path(:summary)

            within "#checkout" do
              expect(page).not_to have_field "order_accept_terms"
              expect(page).not_to have_link "Terms and Conditions"
              expect(page).not_to have_link "Terms of service"
            end
          end
        end

        context "when distributor has T&Cs" do
          before do
            order.distributor.update!(terms_and_conditions: shop_terms)
          end

          describe "when customer has not accepted T&Cs before" do
            it "shows a link to the T&Cs and disables checkout button until terms are accepted" do
              visit checkout_step_path(:summary)
              expect(page).to have_link "Terms and Conditions", href: /Terms-of-service\.pdf/
              expect(page).to have_field "order_accept_terms", checked: false
            end
          end

          describe "when customer has already accepted T&Cs before" do
            before do
              customer.update terms_and_conditions_accepted_at: Time.zone.now
            end

            it "enables checkout button (because T&Cs are accepted by default)" do
              visit checkout_step_path(:summary)
              expect(page).to have_field "order_accept_terms", checked: true
            end

            describe "but afterwards the enterprise has uploaded a new T&Cs file" do
              before { order.distributor.update!(terms_and_conditions: shop_terms) }

              it "disables checkout button until terms are accepted" do
                visit checkout_step_path(:summary)
                expect(page).to have_field "order_accept_terms", checked: false
              end
            end
          end
        end

        context "when the platform's terms of service have to be accepted" do
          before do
            allow(Spree::Config).to receive(:shoppers_require_tos).and_return(true)
          end

          let!(:tos) do
            TermsOfServiceFile.create!(attachment: system_terms)
          end

          it "shows the terms which need to be accepted" do
            visit checkout_step_path(:summary)

            expect(page).to have_link("Terms of service", href: /Terms-of-service.pdf/, count: 2)
            expect(find_link("Terms of service")[:target]).to eq "_blank"
            expect(page).to have_field "order_accept_terms", checked: false
          end

          context "when the terms have been accepted in the past" do
            context "with a dedicated ToS file" do
              before do
                tos.update!(
                  updated_at: 1.day.ago
                )
                customer.update(terms_and_conditions_accepted_at: Time.zone.now)
              end

              it "remembers the selection" do
                visit checkout_step_path(:summary)

                expect(page).to have_link("Terms of service", href: /Terms-of-service.pdf/)
                expect(page).to have_field "order_accept_terms", checked: true
              end
            end

            context "with the default ToS file" do
              before do
                customer.update(terms_and_conditions_accepted_at: Time.zone.now)
              end

              it "remembers the selection" do
                pending "#10675"

                visit checkout_step_path(:summary)

                expect(page).to have_link("Terms of service", href: tos_url)
                expect(page).to have_field "order_accept_terms", checked: true
              end
            end
          end
        end

        context "when the seller's terms and the platform's terms have to be accepted" do
          before do
            order.distributor.update!(terms_and_conditions: shop_terms)

            allow(Spree::Config).to receive(:shoppers_require_tos).and_return(true)
          end

          let!(:tos) do
            TermsOfServiceFile.create!(attachment: system_terms)
          end

          it "shows links to both terms and all need accepting" do
            visit checkout_step_path(:summary)

            expect(page).to have_link "Terms and Conditions", href: /Terms-of-service\.pdf/
            expect(page).to have_link("Terms of service", href: /Terms-of-service\.pdf/, count: 2)
            expect(page).to have_field "order_accept_terms", checked: false
          end
        end
      end

      context "handle the navigation when the order is ready for confirmation" do
        it "redirect to summary step" do
          visit "/checkout"

          expect(page).to have_current_path checkout_step_path(:summary)
        end

        it "handle the navigation between each step by clicking tabs/buttons to submit the form" do
          visit checkout_step_path(:summary)

          click_on "Your details"

          expect(page).to have_current_path checkout_step_path(:details)

          click_on "Next - Payment method"

          expect(page).to have_current_path checkout_step_path(:payment)
        end
      end

      describe "order state" do
        before do
          visit checkout_step_path(:summary)
        end

        it "emptying the cart changes the order state back to address" do
          visit main_app.cart_path
          expect {
            find('#clear_cart_link').click
            expect(page).to have_current_path enterprise_shop_path(distributor)
          }.to change { order.reload.state }.from("confirmation").to("address")
        end
      end

      describe "vouchers" do
        let(:voucher) do
          create(:voucher_flat_rate, code: 'some_code', enterprise: distributor, amount: 6)
        end

        before do
          add_voucher_to_order(voucher, order)
        end

        it "shows the applied voucher" do
          visit checkout_step_path(:summary)

          within ".summary-right" do
            expect(page).to have_content "some_code"
            expect(page).to have_content "-6"
          end
        end

        context "with voucher deactivated after being added to an order" do
          it "completes the order" do
            visit checkout_step_path(:summary)

            # Deactivate voucher
            voucher.destroy

            place_order

            expect(order.reload.state).to eq "complete"
          end
        end
      end

      context "with a VINE voucher", feature: :connected_apps do
        let!(:vine_connected_app) {
          ConnectedApps::Vine.create(
            enterprise: distributor, data: { api_key: "1234568", secret: "my_secret" }
          )
        }
        let(:vine_voucher) {
          create(:vine_voucher, code: 'some_vine_code', enterprise: distributor, amount: 0.01)
        }

        before do
          allow(ENV).to receive(:fetch).and_call_original
          allow(ENV).to receive(:fetch).with("VINE_API_URL")
            .and_return("https://vine-staging.openfoodnetwork.org.au/api/v1")

          add_voucher_to_order(vine_voucher, order)
        end

        it "shows the applied voucher" do
          visit checkout_step_path(:summary)

          within ".summary-right" do
            expect(page).to have_content "some_vine_code"
            expect(page).to have_content "-0.01"
          end
        end

        context "when placing the order" do
          it "completes the order", :vcr do
            visit checkout_step_path(:summary)

            place_order

            within "#line-items" do
              expect(page).to have_content "Voucher: some_vine_code"
              expect(page).to have_content "$-0.01"
            end
            expect(order.reload.state).to eq "complete"
          end
        end
      end
    end

    context "with previous open orders" do
      let(:order) {
        create(:order_ready_for_confirmation, distributor:,
                                              order_cycle:, user_id: user.id)
      }
      let!(:prev_order) {
        create(:completed_order_with_totals,
               order_cycle:, distributor:, user_id: order.user_id)
      }

      context "when distributor allows order changes" do
        before do
          order.distributor.allow_order_changes = true
          order.distributor.save
          visit checkout_step_path(:summary)
        end

        it "informs about previous orders" do
          expect(page).to have_content("You have an order for this order cycle already.")
        end

        it "show a link to /cart#bought-products page" do
          expect(page).to have_link("cart", href: "/cart#bought-products")
          click_on "cart"
          expect(page).to have_text(
            "#{prev_order.line_items.length} " \
            "additional items already confirmed for this order cycle"
          )
        end
      end

      it "don't display any message if distributor don't allow order changes" do
        order.distributor.allow_order_changes = false
        order.distributor.save
        visit checkout_step_path(:summary)

        expect(page).not_to have_content("You have an order for this order cycle already.")
      end
    end

    describe "order confirmation page" do
      let(:completed_order) {
        create(:order_ready_to_ship, distributor:,
                                     order_cycle:, user_id: user.id)
      }
      let(:payment) { completed_order.payments.first }

      context "an order with balance due" do
        before { set_up_order(-10, "balance_due") }

        it "displays balance due and paid state" do
          expect(page).to have_selector('h5', text: "Balance Due")
          expect(page).to have_selector('h5', text: with_currency(10))

          confirmation_page_expect_paid(paid_state: "NOT PAID", paid_amount: 40)
        end
      end

      context "an order with credit owed" do
        before { set_up_order(10, "credit_owed") }

        it "displays Credit owned and paid state" do
          expect(page).to have_selector('h5', text: "Credit Owed")
          expect(page).to have_selector('h5', text: with_currency(-10))

          confirmation_page_expect_paid(paid_state: "PAID", paid_amount: 60)
        end
      end

      context "an order with no outstanding balance" do
        before { set_up_order(0, "paid") }

        it "displays paid state" do
          expect(page).not_to have_selector('h5', text: "Credit Owed")
          expect(page).not_to have_selector('h5', text: "Balance Due")

          confirmation_page_expect_paid(paid_state: "PAID", paid_amount: 50)
        end
      end
    end
  end

  def confirmation_page_expect_paid(paid_state:, paid_amount:)
    expect(page).to have_content paid_state.to_s
    expect(page).to have_selector('strong', text: "Amount Paid")
    expect(page).to have_selector('strong', text: with_currency(paid_amount))
  end

  def add_voucher_to_order(voucher, order)
    voucher.create_adjustment(voucher.code, order)
    OrderManagement::Order::Updater.new(order).update_voucher
  end

  def set_up_order(balance, state)
    payment.update!(amount: payment.amount + balance)
    completed_order.reload
    expect(completed_order.payment_state).to eq state.to_s
    visit "/orders/#{completed_order.number}"
  end
end
