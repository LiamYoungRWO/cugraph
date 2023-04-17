
/*
 * Copyright (c) 2021-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "property_generator.cuh"

#include <utilities/base_fixture.hpp>
#include <utilities/device_comm_wrapper.hpp>
#include <utilities/mg_utilities.hpp>
#include <utilities/test_graphs.hpp>
#include <utilities/test_utilities.hpp>
#include <utilities/thrust_wrapper.hpp>

#include <prims/extract_transform_e.cuh>
#include <prims/update_edge_src_dst_property.cuh>
#include <prims/vertex_frontier.cuh>

#include <cugraph/algorithms.hpp>
#include <cugraph/edge_partition_view.hpp>
#include <cugraph/edge_src_dst_property.hpp>
#include <cugraph/graph_view.hpp>
#include <cugraph/utilities/dataframe_buffer.hpp>
#include <cugraph/utilities/high_res_timer.hpp>

#include <cuco/detail/hash_functions.cuh>

#include <raft/comms/mpi_comms.hpp>
#include <raft/core/comms.hpp>
#include <raft/core/handle.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_uvector.hpp>
#include <sstream>
#include <thrust/copy.h>
#include <thrust/count.h>
#include <thrust/equal.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/optional.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/tabulate.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

#include <gtest/gtest.h>

#include <random>
#include <type_traits>

template <typename key_t, typename vertex_t, typename property_t, typename output_payload_t>
struct e_op_t {
  static_assert(std::is_same_v<key_t, vertex_t> ||
                std::is_same_v<key_t, thrust::tuple<vertex_t, int32_t>>);
  static_assert(std::is_same_v<output_payload_t, int32_t> ||
                std::is_same_v<output_payload_t, thrust::tuple<float, int32_t>>);

  using return_type = thrust::optional<typename std::conditional_t<
    std::is_same_v<key_t, vertex_t>,
    std::conditional_t<std::is_arithmetic_v<output_payload_t>,
                       thrust::tuple<vertex_t, vertex_t, int32_t>,
                       thrust::tuple<vertex_t, vertex_t, float, int32_t>>,
    std::conditional_t<std::is_arithmetic_v<output_payload_t>,
                       thrust::tuple<vertex_t, int32_t, vertex_t, int32_t>,
                       thrust::tuple<vertex_t, int32_t, vertex_t, float, int32_t>>>>;

  __device__ return_type operator()(key_t optionally_tagged_src,
                                    vertex_t dst,
                                    property_t src_val,
                                    property_t dst_val,
                                    thrust::nullopt_t) const
  {
    auto output_payload = static_cast<output_payload_t>(1);
    if (src_val < dst_val) {
      if constexpr (std::is_same_v<key_t, vertex_t>) {
        if constexpr (std::is_arithmetic_v<output_payload_t>) {
          return thrust::make_tuple(optionally_tagged_src, dst, output_payload);
        } else {
          static_assert(thrust::tuple_size<output_payload_t>::value == size_t{2});
          return thrust::make_tuple(optionally_tagged_src,
                                    dst,
                                    thrust::get<0>(output_payload),
                                    thrust::get<1>(output_payload));
        }
      } else {
        static_assert(thrust::tuple_size<key_t>::value == size_t{2});
        if constexpr (std::is_arithmetic_v<output_payload_t>) {
          return thrust::make_tuple(thrust::get<0>(optionally_tagged_src),
                                    thrust::get<1>(optionally_tagged_src),
                                    dst,
                                    output_payload);
        } else {
          static_assert(thrust::tuple_size<output_payload_t>::value == size_t{2});
          return thrust::make_tuple(thrust::get<0>(optionally_tagged_src),
                                    thrust::get<1>(optionally_tagged_src),
                                    dst,
                                    thrust::get<0>(output_payload),
                                    thrust::get<1>(output_payload));
        }
      }
    } else {
      return thrust::nullopt;
    }
  }
};

struct Prims_Usecase {
  bool check_correctness{true};
};

template <typename input_usecase_t>
class Tests_MGExtractTransformE
  : public ::testing::TestWithParam<std::tuple<Prims_Usecase, input_usecase_t>> {
 public:
  Tests_MGExtractTransformE() {}

  static void SetUpTestCase() { handle_ = cugraph::test::initialize_mg_handle(); }

  static void TearDownTestCase() { handle_.reset(); }

  virtual void SetUp() {}
  virtual void TearDown() {}

  // Compare the results of extract_transform_e primitive
  template <typename vertex_t,
            typename edge_t,
            typename weight_t,
            typename tag_t,
            typename output_payload_t>
  void run_current_test(Prims_Usecase const& prims_usecase, input_usecase_t const& input_usecase)
  {
    using result_t = int32_t;

    using key_t =
      std::conditional_t<std::is_same_v<tag_t, void>, vertex_t, thrust::tuple<vertex_t, tag_t>>;

    static_assert(std::is_same_v<tag_t, void> || std::is_arithmetic_v<tag_t>);
    static_assert(std::is_same_v<output_payload_t, void> ||
                  cugraph::is_arithmetic_or_thrust_tuple_of_arithmetic<output_payload_t>::value);
    if constexpr (cugraph::is_thrust_tuple<output_payload_t>::value) {
      static_assert(thrust::tuple_size<output_payload_t>::value == size_t{2});
    }

    HighResTimer hr_timer{};

    // 1. create MG graph

    constexpr bool is_multi_gpu     = true;
    constexpr bool renumber         = true;   // needs to be true for multi gpu case
    constexpr bool store_transposed = false;  // needs to be false for using extract_transform_e
    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.start("MG Construct graph");
    }

    cugraph::graph_t<vertex_t, edge_t, store_transposed, is_multi_gpu> mg_graph(*handle_);
    std::optional<rmm::device_uvector<vertex_t>> d_mg_renumber_map_labels{std::nullopt};
    std::tie(mg_graph, std::ignore, d_mg_renumber_map_labels) =
      cugraph::test::construct_graph<vertex_t, edge_t, weight_t, store_transposed, is_multi_gpu>(
        *handle_, input_usecase, false, renumber);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    auto mg_graph_view = mg_graph.view();

    // 2. run MG extract_transform_e

    const int hash_bin_count = 5;

    auto mg_vertex_prop = cugraph::test::generate<vertex_t, result_t>::vertex_property(
      *handle_, *d_mg_renumber_map_labels, hash_bin_count);
    auto mg_src_prop = cugraph::test::generate<vertex_t, result_t>::src_property(
      *handle_, mg_graph_view, mg_vertex_prop);
    auto mg_dst_prop = cugraph::test::generate<vertex_t, result_t>::dst_property(
      *handle_, mg_graph_view, mg_vertex_prop);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.start("MG extract_transform_e");
    }

    auto mg_extract_transform_output_buffer =
      cugraph::extract_transform_e(*handle_,
                                   mg_graph_view,
                                   mg_src_prop.view(),
                                   mg_dst_prop.view(),
                                   cugraph::edge_dummy_property_t{}.view(),
                                   e_op_t<key_t, vertex_t, result_t, output_payload_t>{});

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      handle_->get_comms().barrier();
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    // 3. compare SG & MG results

    if (prims_usecase.check_correctness) {
      auto mg_aggregate_extract_transform_output_buffer = cugraph::allocate_dataframe_buffer<
        typename e_op_t<key_t, vertex_t, result_t, output_payload_t>::return_type::value_type>(
        size_t{0}, handle_->get_stream());
      std::get<0>(mg_aggregate_extract_transform_output_buffer) =
        cugraph::test::device_gatherv(*handle_,
                                      std::get<0>(mg_extract_transform_output_buffer).data(),
                                      std::get<0>(mg_extract_transform_output_buffer).size());
      std::get<1>(mg_aggregate_extract_transform_output_buffer) =
        cugraph::test::device_gatherv(*handle_,
                                      std::get<1>(mg_extract_transform_output_buffer).data(),
                                      std::get<1>(mg_extract_transform_output_buffer).size());
      std::get<2>(mg_aggregate_extract_transform_output_buffer) =
        cugraph::test::device_gatherv(*handle_,
                                      std::get<2>(mg_extract_transform_output_buffer).data(),
                                      std::get<2>(mg_extract_transform_output_buffer).size());
      if constexpr (!std::is_same_v<key_t, vertex_t> || !std::is_arithmetic_v<output_payload_t>) {
        std::get<3>(mg_aggregate_extract_transform_output_buffer) =
          cugraph::test::device_gatherv(*handle_,
                                        std::get<3>(mg_extract_transform_output_buffer).data(),
                                        std::get<3>(mg_extract_transform_output_buffer).size());
      }
      if constexpr (!std::is_same_v<key_t, vertex_t> && !std::is_arithmetic_v<output_payload_t>) {
        std::get<4>(mg_aggregate_extract_transform_output_buffer) =
          cugraph::test::device_gatherv(*handle_,
                                        std::get<4>(mg_extract_transform_output_buffer).data(),
                                        std::get<4>(mg_extract_transform_output_buffer).size());
      }

      cugraph::graph_t<vertex_t, edge_t, store_transposed, false> sg_graph(*handle_);
      std::tie(sg_graph, std::ignore, std::ignore) = cugraph::test::mg_graph_to_sg_graph(
        *handle_,
        mg_graph_view,
        std::optional<cugraph::edge_property_view_t<edge_t, weight_t const*>>{std::nullopt},
        std::make_optional<raft::device_span<vertex_t const>>((*d_mg_renumber_map_labels).data(),
                                                              (*d_mg_renumber_map_labels).size()),
        false);
      rmm::device_uvector<result_t> sg_vertex_prop(0, handle_->get_stream());
      std::tie(std::ignore, sg_vertex_prop) =
        cugraph::test::mg_vertex_property_values_to_sg_vertex_property_values(
          *handle_,
          std::make_optional<raft::device_span<vertex_t const>>((*d_mg_renumber_map_labels).data(),
                                                                (*d_mg_renumber_map_labels).size()),
          mg_graph_view.local_vertex_partition_range(),
          std::optional<raft::device_span<vertex_t const>>{std::nullopt},
          std::optional<raft::device_span<vertex_t const>>{std::nullopt},
          raft::device_span<result_t const>(mg_vertex_prop.data(), mg_vertex_prop.size()));

      if (handle_->get_comms().get_rank() == int{0}) {
        thrust::sort(
          handle_->get_thrust_policy(),
          cugraph::get_dataframe_buffer_begin(mg_aggregate_extract_transform_output_buffer),
          cugraph::get_dataframe_buffer_end(mg_aggregate_extract_transform_output_buffer));

        auto sg_graph_view = sg_graph.view();

        auto sg_src_prop = cugraph::test::generate<vertex_t, result_t>::src_property(
          *handle_, sg_graph_view, sg_vertex_prop);
        auto sg_dst_prop = cugraph::test::generate<vertex_t, result_t>::dst_property(
          *handle_, sg_graph_view, sg_vertex_prop);

        auto sg_extract_transform_output_buffer =
          cugraph::extract_transform_e(*handle_,
                                       sg_graph_view,
                                       sg_src_prop.view(),
                                       sg_dst_prop.view(),
                                       cugraph::edge_dummy_property_t{}.view(),
                                       e_op_t<key_t, vertex_t, result_t, output_payload_t>{});

        thrust::sort(handle_->get_thrust_policy(),
                     cugraph::get_dataframe_buffer_begin(sg_extract_transform_output_buffer),
                     cugraph::get_dataframe_buffer_end(sg_extract_transform_output_buffer));

        bool e_op_result_passed = thrust::equal(
          handle_->get_thrust_policy(),
          cugraph::get_dataframe_buffer_begin(sg_extract_transform_output_buffer),
          cugraph::get_dataframe_buffer_begin(sg_extract_transform_output_buffer),
          cugraph::get_dataframe_buffer_end(mg_aggregate_extract_transform_output_buffer));
        ASSERT_TRUE(e_op_result_passed);
      }
    }
  }

 private:
  static std::unique_ptr<raft::handle_t> handle_;
};

template <typename input_usecase_t>
std::unique_ptr<raft::handle_t> Tests_MGExtractTransformE<input_usecase_t>::handle_ = nullptr;

using Tests_MGExtractTransformE_File = Tests_MGExtractTransformE<cugraph::test::File_Usecase>;
using Tests_MGExtractTransformE_Rmat = Tests_MGExtractTransformE<cugraph::test::Rmat_Usecase>;

TEST_P(Tests_MGExtractTransformE_File, CheckInt32Int32FloatVoidInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, void, int32_t>(std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt32Int32FloatVoidInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, void, int32_t>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGExtractTransformE_File, CheckInt32Int32FloatVoidTupleFloatInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, void, thrust::tuple<float, int32_t>>(
    std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt32Int32FloatVoidTupleFloatInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, void, thrust::tuple<float, int32_t>>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGExtractTransformE_File, CheckInt32Int32FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int32_t, int32_t>(std::get<0>(param),
                                                              std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt32Int32FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int32_t, int32_t>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGExtractTransformE_File, CheckInt32Int32FloatInt32TupleFloatInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int32_t, thrust::tuple<float, int32_t>>(
    std::get<0>(param), std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt32Int32FloatInt32TupleFloatInt32)
{
  auto param = GetParam();
  run_current_test<int32_t, int32_t, float, int32_t, thrust::tuple<float, int32_t>>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGExtractTransformE_File, CheckInt32Int64FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, int32_t, int32_t>(std::get<0>(param),
                                                              std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt32Int64FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int32_t, int64_t, float, int32_t, int32_t>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

TEST_P(Tests_MGExtractTransformE_File, CheckInt64Int64FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, int32_t, int32_t>(std::get<0>(param),
                                                              std::get<1>(param));
}

TEST_P(Tests_MGExtractTransformE_Rmat, CheckInt64Int64FloatInt32Int32)
{
  auto param = GetParam();
  run_current_test<int64_t, int64_t, float, int32_t, int32_t>(
    std::get<0>(param),
    cugraph::test::override_Rmat_Usecase_with_cmd_line_arguments(std::get<1>(param)));
}

INSTANTIATE_TEST_SUITE_P(
  file_test,
  Tests_MGExtractTransformE_File,
  ::testing::Combine(
    ::testing::Values(Prims_Usecase{true}),
    ::testing::Values(cugraph::test::File_Usecase("test/datasets/karate.mtx"),
                      cugraph::test::File_Usecase("test/datasets/web-Google.mtx"),
                      cugraph::test::File_Usecase("test/datasets/ljournal-2008.mtx"),
                      cugraph::test::File_Usecase("test/datasets/webbase-1M.mtx"))));

INSTANTIATE_TEST_SUITE_P(rmat_small_test,
                         Tests_MGExtractTransformE_Rmat,
                         ::testing::Combine(::testing::Values(Prims_Usecase{true}),
                                            ::testing::Values(cugraph::test::Rmat_Usecase(
                                              10, 16, 0.57, 0.19, 0.19, 0, false, false))));

INSTANTIATE_TEST_SUITE_P(
  rmat_benchmark_test, /* note that scale & edge factor can be overridden in benchmarking (with
                          --gtest_filter to select only the rmat_benchmark_test with a specific
                          vertex & edge type combination) by command line arguments and do not
                          include more than one Rmat_Usecase that differ only in scale or edge
                          factor (to avoid running same benchmarks more than once) */
  Tests_MGExtractTransformE_Rmat,
  ::testing::Combine(
    ::testing::Values(Prims_Usecase{false}),
    ::testing::Values(cugraph::test::Rmat_Usecase(20, 32, 0.57, 0.19, 0.19, 0, false, false))));

CUGRAPH_MG_TEST_PROGRAM_MAIN()